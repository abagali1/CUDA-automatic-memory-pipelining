//===-- Frequent Path Loop Invariant Code Motion Pass --------------------===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===---------------------------------------------------------------------===//
//
// EECS583 W25 - This pass can be used as a template for your FPLICM homework
//               assignment.
//               The passes get registered as "fplicm-correctness" and
//               "fplicm-performance".
//
//
////===-------------------------------------------------------------------===//
#include "llvm/Analysis/BlockFrequencyInfo.h"
#include "llvm/Analysis/BranchProbabilityInfo.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/LoopIterator.h"
#include "llvm/Analysis/LoopPass.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/SSAUpdater.h"

/* *******Implementation Starts Here******* */
#include <math.h>
#include <deque>
#include <vector>
#include <string>
#include <utility>
#include <unordered_set>

/* *******Implementation Ends Here******* */

using namespace llvm;

const uint64_t MAX_SHARED_MEM = 163 * 1024;

namespace {
  struct PipelinePass : public PassInfoMixin<PipelinePass> {
    size_t tile_size = 0;
    Module *top_level_module;

    std::tuple<unsigned, std::string, uint64_t> traceOriginalAddressSpace(Value *V,  unsigned MaxDepth = 16) {
      for (unsigned Depth = 0; Depth < MaxDepth; ++Depth) {
          V = V->stripPointerCasts();
          // Case 1: Global variable (e.g., shared memory tile)
          if (auto *GV = dyn_cast<GlobalVariable>(V)) {
              Type *Ty = GV->getValueType();
              const DataLayout &DL = GV->getParent()->getDataLayout();
              uint64_t Size = DL.getTypeAllocSize(Ty);
              return { GV->getAddressSpace(), std::string(GV->getName()), Size};
          }
          // Case 2: Function argument
          if (auto *Arg = dyn_cast<Argument>(V)) {
            if (PointerType *PT = dyn_cast<PointerType>(Arg->getType())) {
              return { PT->getAddressSpace(), "arg", 0}; // size unknown
            }
          }
          // Case 3: Alloca
          if (auto *AI = dyn_cast<AllocaInst>(V)) {
            const DataLayout &DL = AI->getModule()->getDataLayout(); 
            Type *Ty = AI->getAllocatedType();
            uint64_t Size = DL.getTypeAllocSize(Ty);
            return { AI->getType()->getAddressSpace(), "alloca", Size};
          }
          // Recursively trace through these:
          if (auto *GEP = dyn_cast<GetElementPtrInst>(V)) {
              V = GEP->getPointerOperand();
              continue;
          }
          if (auto *LI = dyn_cast<LoadInst>(V)) {
              V = LI->getPointerOperand();
              continue;
          }
          if (auto *PHI = dyn_cast<PHINode>(V)) {
              if (Value *Incoming = PHI->getIncomingValue(0)) {
                  V = Incoming;
                  continue;
              }
          }
          break; // Unknown source or not traceable further
      }
      return { static_cast<unsigned>(-1), "", 0}; // Unknown
    }

    bool is_barrier(Instruction &i){
      if (auto *CI = dyn_cast<CallInst>(&i)) {
        if (Function *F = CI->getCalledFunction()) {
            if (F->getName() == "llvm.nvvm.barrier0") {
              return true;
            }
        }
        if (auto *IA = dyn_cast<InlineAsm>(CI->getCalledOperand())) {
          StringRef AsmStr = IA->getAsmString();
          if (AsmStr.contains("bar.sync")) {
            return true;
          }
        }
      }
      return false;
    }

    void resizeSharedMemoryArray(StringRef VarName, uint64_t new_num_elements) {
      Module &M = *this->top_level_module;
      LLVMContext &Ctx = M.getContext();
      const DataLayout &DL = M.getDataLayout();

      for (GlobalVariable &GV : M.globals()) {
          if (GV.getName() == VarName && GV.getAddressSpace() == 3) {
              // Get the element type (e.g., float)
              Type *Ty = GV.getValueType();
              // Create a new larger array type
              ArrayType *NewArrayTy = ArrayType::get(Ty->getArrayElementType(), new_num_elements);
              // Clone global with new type
              GlobalVariable *NewGV = new GlobalVariable(
                  M,
                  NewArrayTy,
                  /*isConstant=*/GV.isConstant(),
                  GlobalValue::LinkOnceODRLinkage,
                  /*Initializer=*/UndefValue::get(NewArrayTy), // Must be null for shared mem
                  GV.getName() + "resized",
                  /*InsertBefore=*/nullptr,
                  GV.getThreadLocalMode(),
                  GV.getAddressSpace(),
                  true
                );
              NewGV->copyAttributesFrom(&GV);
              // Replace all uses (with proper bitcasts if needed)
              GV.replaceAllUsesWith(ConstantExpr::getBitCast(NewGV, GV.getType()));
              // (Optional) Erase old GV
              GV.eraseFromParent();
              errs() << "✅ Resized shared memory array: " << VarName << " " << new_num_elements << "\n";
              return;
          }
      }
    }

    std::unordered_map<Instruction*, Instruction*> check_transfer_reqs(std::vector<BasicBlock*> &path){
      size_t total_shared_usage = 0;
      std::unordered_map<std::string, uint64_t> buffers;
      std::unordered_map<Instruction*, Instruction*> load_store_pairs;

      for(BasicBlock *b: path){
        for(Instruction &i: *b){
          if (auto *SI = dyn_cast<StoreInst>(&i)) {
            auto [addr_space, symbol, size] = traceOriginalAddressSpace(SI->getPointerOperand());
            if(addr_space == 3){
              // find corresponding global load
              errs() << "SZ: " << size << "\n";
              if(auto *LI = dyn_cast<LoadInst>(SI->getValueOperand())){
                load_store_pairs[LI] = SI;
                if(buffers.find(symbol) == buffers.end()){
                  buffers[symbol] = size;
                  this->tile_size = sqrt(size);
                  total_shared_usage += size;
                }
              }
            }
          }
        }
      }
      if(total_shared_usage * 2 > MAX_SHARED_MEM || load_store_pairs.empty()){
        return {};
      }else{
        for(auto it: buffers){
          resizeSharedMemoryArray(it.first, it.second / 2); // Implicit conversion from size (bytes) to 2x num_elements (count). Assumes float
        }
      }

      return load_store_pairs;
    }

    std::vector<BasicBlock*> loop_traverse(Loop *l, BasicBlock *start, BasicBlock *end){
      std::deque<BasicBlock*> q;
      std::unordered_set<BasicBlock*> visited;
      std::vector<BasicBlock*> path;

      q.push_back(start);
      visited.insert(start);

      bool reached = false;
      while(!q.empty()){
        BasicBlock *cur_node = q.front();
        q.pop_front();

        if(cur_node == end){
          reached = true;
        }

        path.push_back(cur_node);

        if(reached)
          break;

        for(BasicBlock *s: successors(cur_node)){
          if(l->contains(s) && visited.insert(s).second){
            q.push_back(s);
          }
        }
      }
      return path;
    }

    bool is_tiling_loop(Loop *l, std::unordered_map<Instruction*, Instruction*> &final_pairs){
      if(l->getParentLoop() != nullptr){
        return false;
      }
      auto blocks = l->blocks();
      auto header = l->getHeader();

      std::deque<BasicBlock*> q;
      std::unordered_set<BasicBlock*> visited;

      Instruction *first_barrier = nullptr;
      Instruction *second_barrier = nullptr;

      q.push_back(header);
      visited.insert(header);

      while(!q.empty()){
        BasicBlock *cur_node = q.front();
        q.pop_front();

        Instruction &term = cur_node->back();
        for(unsigned i=0;i<term.getNumSuccessors();i++){
          BasicBlock *s = term.getSuccessor(i);
          if(visited.find(s) == visited.end()){
            q.push_back(s);
            visited.insert(s);
          }
        }

        for(Instruction &i: *cur_node){
          if(is_barrier(i)){
            if(first_barrier == nullptr){
              first_barrier = &i;
            }else if(second_barrier == nullptr){
              second_barrier = &i;
            }else{
              errs() << "UNKOWN BAR\n";
              return false; // unknown barrier usage
            }
          }
        }
      }
      if(first_barrier == nullptr || second_barrier == nullptr){
        errs() << "NO BAR\n";
        return false;
      }

      std::vector<BasicBlock*> barrier_traversal = loop_traverse(l, header, first_barrier->getParent());

      // verify global->shared pattern and return instruction pairs
      auto load_store_pairs = check_transfer_reqs(barrier_traversal);
      if(load_store_pairs.empty()){
        barrier_traversal = loop_traverse(l, first_barrier->getParent(), header);
        load_store_pairs = check_transfer_reqs(barrier_traversal);

        if(load_store_pairs.empty()){
          errs() << "NO TRANSFER\n";
          return false;
        }
      }

      final_pairs = load_store_pairs;
      return true;
    }

    PHINode *getInductionVariable(llvm::Loop *L) {
      BasicBlock *Header = L->getHeader();
      for (Instruction &I : *Header) {
          if (PHINode *PN = dyn_cast<PHINode>(&I)) {
              // Must have two incoming values: from preheader and latch
              if (PN->getNumIncomingValues() != 2)
                  continue;

              BasicBlock *Preheader = L->getLoopPreheader();
              BasicBlock *Latch     = L->getLoopLatch();

              if (!Preheader || !Latch)
                  continue;

              Value *Init = PN->getIncomingValueForBlock(Preheader);
              Value *Step = PN->getIncomingValueForBlock(Latch);

              // Optionally: check if step is `add i32 %phi, 1`
              if (BinaryOperator *BO = dyn_cast<BinaryOperator>(Step)) {
                  if (BO->getOpcode() == Instruction::Add &&
                      BO->getOperand(0) == PN || BO->getOperand(1) == PN) {
                      return PN;
                  }
              }
          }
      }
      return nullptr; // Not found
    }

    void replaceLSPairs(llvm::Loop *L, std::unordered_map<llvm::Instruction *, llvm::Instruction *> &load_store_pairs)
    {
      BasicBlock *Preheader = L->getLoopPreheader();
      if (!Preheader)
        return;

      // llvm::LLVMContext context;
      // IRBuilder<> insertBuilder;
      CallInst *lastInserted = nullptr;
      for (auto &pair : load_store_pairs)
      {
        auto *loadInst = dyn_cast<LoadInst>(pair.first);
        auto *storeInst = dyn_cast<StoreInst>(pair.second);

        Value *srcGlobalAddr = loadInst->getPointerOperand();
        Value *dstSharedAddr = storeInst->getPointerOperand();

        IRBuilder<> insertBuilder(storeInst);

        // Cast operands to expected types
        Value *dstInt = insertBuilder.CreatePtrToInt(dstSharedAddr, insertBuilder.getInt32Ty(), "sharedAddrCase");
        Value *srcPtr = insertBuilder.CreateBitCast(srcGlobalAddr, insertBuilder.getInt8Ty()->getPointerTo(), "globalAddrCast");

        // Create function type for inline asm
        std::vector<Type *> argTypes = {
            insertBuilder.getInt32Ty(),
            insertBuilder.getInt8Ty()->getPointerTo()};

        FunctionType *asmTy = FunctionType::get(insertBuilder.getVoidTy(), argTypes, false);
        InlineAsm *cpAsync = InlineAsm::get(asmTy,
                                            "cp.async.ca.shared.global [$0], [$1], 4, 4;",
                                            "r,l",
                                            true // hasSideEffects
        );

        // // Insert inline asm into loop where load originally was
        // errs() << "BEFORE CREATE CALL\n";
        CallInst *inserted = insertBuilder.CreateCall(cpAsync, {dstInt, srcPtr});

        if(lastInserted == nullptr || lastInserted->comesBefore(inserted)){
          lastInserted = inserted;
        }
        // errs() << "AFTER CREATE CALL\n";
        // // Erase the original load and store
        storeInst->eraseFromParent();
        loadInst->eraseFromParent();
      }
      IRBuilder<> insertBuilder(lastInserted->getNextNode());
      FunctionType *commitType = FunctionType::get(insertBuilder.getVoidTy(), {}, false);
      InlineAsm *commitAsync = InlineAsm::get(commitType, "cp.async.commit_group;", "", true);
      InlineAsm *waitGroup = InlineAsm::get(commitType, "cp.async.wait_group 0;", "", true);
      insertBuilder.CreateCall(commitAsync, {});
      insertBuilder.CreateCall(waitGroup, {});

    }

    PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM) {
      llvm::BlockFrequencyAnalysis::Result &bfi = FAM.getResult<BlockFrequencyAnalysis>(F);
      llvm::BranchProbabilityAnalysis::Result &bpi = FAM.getResult<BranchProbabilityAnalysis>(F);
      llvm::LoopAnalysis::Result &li = FAM.getResult<LoopAnalysis>(F);
      /* *******Implementation Starts Here******* */
      errs() << "Passing function: " << F.getName() << "\n";
      this->top_level_module = F.getParent();
      for(Loop *L: li){
        std::unordered_map<Instruction*, Instruction*> load_store_pairs;
        if(is_tiling_loop(L, load_store_pairs)){
            replaceLSPairs(L, load_store_pairs);
              // insert 2 cp.asyncs into loop preheader
              // For every load-store pair
              // Find load base addr
              // Find store base addr
              // Create cp.async wit
              errs()
              << "GOOD " << load_store_pairs.size() << "\n";
          PHINode *ind = getInductionVariable(L);
          ind->print(errs());
          errs() << "\n";
        }else{
          errs() << "BAD!\n";
        }
      }

      /* *******Implementation Ends Here******* */
      // Your pass is modifying the source code. Figure out which analyses
      // are preserved and only return those, not all.
      return PreservedAnalyses::all();
    }
  };
}

extern "C" ::llvm::PassPluginLibraryInfo LLVM_ATTRIBUTE_WEAK llvmGetPassPluginInfo() {
  return {
    LLVM_PLUGIN_API_VERSION, "PipePass", "v0.1",
    [](PassBuilder &PB) {
      PB.registerPipelineParsingCallback(
        [](StringRef Name, FunctionPassManager &FPM,
        ArrayRef<PassBuilder::PipelineElement>) {
          if(Name == "pipe"){
            FPM.addPass(PipelinePass());
            return true;
          }
          return false;
        }
      );
    }
  };
}