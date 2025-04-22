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
#include <set>
#include <map>
#include <unordered_set>

/* *******Implementation Ends Here******* */

using namespace llvm;

const uint64_t MAX_SHARED_MEM = 163 * 1024;

namespace {
  struct PipelinePass : public PassInfoMixin<PipelinePass> {
    size_t tile_size = 0;
    Module *top_level_module;
    llvm::DominatorTree *DT;

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
              return;
          }
      }
    }

    std::map<Instruction*, Instruction*> check_transfer_reqs(std::vector<BasicBlock*> &path){
      size_t total_shared_usage = 0;
      std::unordered_map<std::string, uint64_t> buffers;
      std::map<Instruction*, Instruction*> load_store_pairs;

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
          resizeSharedMemoryArray(it.first, 2048); // Implicit conversion from size (bytes) to 2x num_elements (count). Assumes float
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

    bool is_tiling_loop(Loop *l, std::map<Instruction*, Instruction*> &final_pairs, BasicBlock* &first_barrier_bb, BasicBlock* &second_barrier_bb){
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

      first_barrier_bb = first_barrier->getParent();
      second_barrier_bb = second_barrier->getParent();

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

    void traceDependencies(llvm::Loop *L, llvm::Value *val, std::vector<Instruction*> &chain, std::set<llvm::Instruction*> &seen) {
      if (auto *inst = llvm::dyn_cast<llvm::Instruction>(val)) {
          // Avoid revisiting
          bool inOrBeforeLoopHeader = inst->getParent() == L->getHeader() || DT->dominates(inst, &*L->getHeader()->begin());
          if(inst->comesBefore(&L->getHeader()->back()) || inOrBeforeLoopHeader)
            return;

          if (!seen.insert(inst).second)
              return;

          chain.push_back(inst);

          // Recurse on operands
          for (llvm::Value *op : inst->operands()) {
              traceDependencies(L, op, chain, seen);
          }
      }
    }

    std::vector<std::vector<Instruction*>> replaceLSPairs(llvm::Loop *L, std::map<llvm::Instruction *, llvm::Instruction *> &load_store_pairs)
    {
      BasicBlock *Preheader = L->getLoopPreheader();

      // llvm::LLVMContext context;
      // IRBuilder<> insertBuilder;
      CallInst *lastInserted = nullptr;
      std::vector<std::vector<Instruction*>> depchains;
      for (auto &pair : load_store_pairs)
      {
        auto *loadInst = dyn_cast<LoadInst>(pair.first);
        auto *storeInst = dyn_cast<StoreInst>(pair.second);

        Value *srcGlobalAddr = loadInst->getPointerOperand();
        Value *dstSharedAddr = storeInst->getPointerOperand();

        IRBuilder<> insertBuilder(storeInst);

        // Cast operands to expected types

        // Create function type for inline asm
        std::vector<Type *> argTypes = {
            insertBuilder.getInt32Ty(),
            insertBuilder.getInt8Ty()->getPointerTo()};

        FunctionType *convertType = FunctionType::get(insertBuilder.getInt64Ty(), {insertBuilder.getInt8Ty()->getPointerTo()}, false);
        llvm::FunctionCallee cvtaFunc = loadInst->getParent()->getModule()->getOrInsertFunction("__nv_cvta_generic_to_shared_impl", convertType);
        Value *sharedAddrInt = insertBuilder.CreateCall(cvtaFunc, {dstSharedAddr}, "shared_int");

        Value *dstInt = insertBuilder.CreateTrunc(sharedAddrInt, insertBuilder.getInt32Ty(), "trunc_i64_to_i32");
        Value *srcPtr = insertBuilder.CreateBitCast(srcGlobalAddr, insertBuilder.getInt8Ty()->getPointerTo(), "globalAddrCast");

        FunctionType *asmTy = FunctionType::get(insertBuilder.getVoidTy(), argTypes, false);
        InlineAsm *cpAsync = InlineAsm::get(asmTy,
                                            "cp.async.ca.shared.global [$0], [$1], 4, 4;",
                                            "r,l",
                                            true // hasSideEffects
        );


        CallInst *inserted = insertBuilder.CreateCall(cpAsync, {dstInt, srcPtr});

        if(lastInserted == nullptr || lastInserted->comesBefore(inserted)){
          lastInserted = inserted;
        }

        storeInst->eraseFromParent();
        loadInst->eraseFromParent();

        std::set<Instruction*> visited;
        std::vector<Instruction*> chain;
        traceDependencies(L, inserted, chain, visited);
        std::sort(chain.begin(), chain.end(), [](Instruction* a, Instruction *b){
          return a->comesBefore(b);
        });
        depchains.push_back(std::move(chain));
      }

      return depchains;
    }

    llvm::Value* replaceTxBasicBlock(std::vector<std::vector<Instruction*>> &depchains, PHINode *ind) {
      
      // for (auto it = bb->begin(), end = bb->end(); it != end;) {
      //   Instruction *inst = &*it++;
        
      //   // Erase the instruction from the current BasicBlock
      //   inst->eraseFromParent();
      // }

      BasicBlock *bb = ind->getParent()->getTerminator()->getSuccessor(0);

      IRBuilder<> insertBuilder(bb->getFirstNonPHI());
  
      Value *two = insertBuilder.getInt32(2);
      Value *stage = insertBuilder.CreateURem(ind, two, "stage");
  
      FunctionType *waitType = FunctionType::get(insertBuilder.getVoidTy(), {}, false);
      InlineAsm *waitAsync = InlineAsm::get(waitType, "cp.async.wait_group 1;", "", true);
  
      insertBuilder.CreateCall(waitAsync, {});

      return stage;
  }
  


    void addAsyncTransfer(BasicBlock* bb, std::vector<std::vector<Instruction*>> &depchains, PHINode *inductor, llvm::Value *stage) {
      IRBuilder<> insertBuilder(&bb->back());
  
      Value *inductorPlus2 = insertBuilder.CreateAdd(inductor, ConstantInt::get(inductor->getType(), 2), "inductor_plus_2");
 
      llvm::ValueToValueMapTy VMap1;

      for (auto& chain : depchains) {
          for (Instruction *inst : chain) {
              Instruction *cloned = inst->clone();
  
              for (unsigned i = 0; i < cloned->getNumOperands(); ++i) {
                if (cloned->getOperand(i) == inductor) {
                  cloned->setOperand(i, inductorPlus2);
                }
              }

              if(auto *gep = dyn_cast<GetElementPtrInst>(cloned)){
                auto *addr_ptr = gep->getPointerOperand();
                // gep->print(errs());
                auto [addr_space, symbol, space] = traceOriginalAddressSpace(addr_ptr);
                // errs() << " " << addr_space << '\n';
                if(addr_space == 3){
                  cloned->setOperand(1, stage);
                }
              }
  
              if (cloned == inductor) {
                for (unsigned i = 0; i < inductor->getNumOperands(); ++i) {
                  inductor->setIncomingValue(i, inductorPlus2);
                }
              }

              llvm::RemapInstruction(cloned, VMap1, RF_NoModuleLevelChanges);
              insertBuilder.Insert(cloned);
              VMap1[inst] = cloned;
          }
      }
  
      FunctionType *commitType = FunctionType::get(insertBuilder.getVoidTy(), {}, false);
      InlineAsm *commitAsync = InlineAsm::get(commitType, "cp.async.commit_group;", "", true);
      insertBuilder.CreateCall(commitAsync, {});
  }


    Value *getLoopLimit(Loop *L) {
      // Step 1: Get canonical induction variable
      PHINode *IndVar = L->getCanonicalInductionVariable();
      if (!IndVar) {
          errs() << "Loop does not have a canonical induction variable.\n";
          return nullptr;
      }
  
      // Step 2: Get the unique exiting block
      BasicBlock *ExitingBlock = L->getExitingBlock();
      if (!ExitingBlock) {
          errs() << "Loop does not have a unique exiting block.\n";
          return nullptr;
      }
  
      // Step 3: Get the conditional branch instruction
      BranchInst *BI = dyn_cast<BranchInst>(ExitingBlock->getTerminator());
      if (!BI || !BI->isConditional()) {
          errs() << "Exiting block does not end with a conditional branch.\n";
          return nullptr;
      }
  
      // Step 4: Get the condition and cast it to a compare instruction
      ICmpInst *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
      if (!Cmp) {
          errs() << "Expected ICmp instruction in the branch condition.\n";
          return nullptr;
      }
  
      // Step 5: Identify which operand is the induction variable
      Value *Op0 = Cmp->getOperand(0);
      Value *Op1 = Cmp->getOperand(1);
  
      if (Op0 == IndVar) {
          return Op1; // limit is the other operand
      } else if (Op1 == IndVar) {
          return Op0;
      }
  
      errs() << "Induction variable is not part of the comparison.\n";
      return nullptr;
  }

    BasicBlock* addMemTransferCondition(BasicBlock* BB, PHINode* ind, Value* loop_limit) {

      Instruction *Term = BB->getTerminator();
      if (!Term) {
          errs() << "Basic block does not have a terminator!\n";
          return nullptr;
      }
  
      // Get the successor before removing the terminator
      Instruction *OldTerm = BB->getTerminator();
      if (OldTerm->getNumSuccessors() == 0) {
          errs() << "Expected the basic block to have at least one successor\n";
          return nullptr;
      }
      BasicBlock *OriginalSuccessor = OldTerm->getSuccessor(0);
      
      // Remove the old terminator
      OldTerm->eraseFromParent();

      // Create an IRBuilder at the end of the basic block
      IRBuilder<> Builder(BB);

      // Compute InductionVar + 2
      Value *IndPlus2 = Builder.CreateAdd(ind, ConstantInt::get(ind->getType(), 2), "indplus2");

      // Compare (ind + 2) < loop limit
      Value *Cond = Builder.CreateICmpSLT(IndPlus2, loop_limit, "cond");

      // Create a new basic block for the 'then' branch (loop continuation)
      Function *F = BB->getParent();
      BasicBlock *ThenBB = BasicBlock::Create(BB->getContext(), "new_mem_transfer", F);

      // Add a branch based on the condition
      Builder.CreateCondBr(Cond, ThenBB, OriginalSuccessor);

      // Add a dummy terminator to the new 'then' block for now
      IRBuilder<> ThenBuilder(ThenBB);
      ThenBuilder.CreateBr(OriginalSuccessor); // you can customize this branch target as needed

      return ThenBB;
    }



    void printDepchains(std::vector<std::vector<Instruction*>> &depchains) {
      for (unsigned i = 0; i < depchains.size(); ++i) {
        errs() << "Depchain " << i << ":\n";
        for (Instruction *inst : depchains[i]) {
          // Print the instruction opcode and its operands (if any)
          errs() << "  Instruction: " << *inst << "\n";
        }
      }
    }

    PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM) {
      llvm::BlockFrequencyAnalysis::Result &bfi = FAM.getResult<BlockFrequencyAnalysis>(F);
      llvm::BranchProbabilityAnalysis::Result &bpi = FAM.getResult<BranchProbabilityAnalysis>(F);
      llvm::LoopAnalysis::Result &li = FAM.getResult<LoopAnalysis>(F);
      /* *******Implementation Starts Here******* */

      DT =  &FAM.getResult<llvm::DominatorTreeAnalysis>(F);
      errs() << "Passing function: " << F.getName() << "\n";
      this->top_level_module = F.getParent();
      for(Loop *L: li){
        std::map<Instruction*, Instruction*> load_store_pairs;
        BasicBlock* second_barrier_bb;
        BasicBlock* first_barrier_bb;
        if(is_tiling_loop(L, load_store_pairs, first_barrier_bb, second_barrier_bb)){
          std::vector<std::vector<Instruction*>> depchains = replaceLSPairs(L, load_store_pairs);
          PHINode *ind = getInductionVariable(L);
          auto *preheader = L->getLoopPreheader();

          llvm::IRBuilder<> builder(preheader->getTerminator());
          llvm::ValueToValueMapTy VMap1, VMap2;

          for(int i=0;i<2;i++){
            for(auto &chain: depchains){
              for(Instruction *inst: chain){
                // inst->print(errs());
                // errs() << " " << inst->getName() << "\n";
                Instruction *clone = inst->clone();
                auto preheader = L->getLoopPreheader();

                for(unsigned o=0;o < clone->getNumOperands(); o++){
                  if(clone->getOperand(o) == ind){
                    llvm::ConstantInt *const_stage = llvm::ConstantInt::get(llvm::Type::getInt32Ty(clone->getContext()), i);
                    clone->setOperand(o, const_stage);
                  }
                }

                if(auto *gep = dyn_cast<GetElementPtrInst>(clone)){
                  auto *addr_ptr = gep->getPointerOperand();
                  // gep->print(errs());
                  auto [addr_space, symbol, space] = traceOriginalAddressSpace(addr_ptr);
                  // errs() << " " << addr_space << '\n';
                  if(addr_space == 3){
                    clone->setOperand(1, llvm::ConstantInt::get(llvm::Type::getInt32Ty(inst->getContext()), i));
                  }
                }

                if(i == 0){
                  llvm::RemapInstruction(clone, VMap1, RF_NoModuleLevelChanges);
                  builder.Insert(clone);
                  VMap1[inst] = clone;
                }else{
                  llvm::RemapInstruction(clone, VMap2, RF_NoModuleLevelChanges);
                  builder.Insert(clone);
                  VMap2[inst] = clone;
                }
              }
            }
            FunctionType *commitType = FunctionType::get(builder.getVoidTy(), {}, false);
            InlineAsm *commitAsync = InlineAsm::get(commitType, "cp.async.commit_group;", "", true);
            builder.CreateCall(commitAsync, {});
          }

          BasicBlock* mem_transfer_bb = addMemTransferCondition(second_barrier_bb, ind, getLoopLimit(L));
          llvm::Value *stage = replaceTxBasicBlock(depchains, ind);
          addAsyncTransfer(mem_transfer_bb, depchains, ind, stage);

          for (auto chain : depchains) {
            for (auto* inst : chain) {
              // inst->replaceAllUsesWith(UndefValue::get(inst->getType()));
              inst->eraseFromParent();
            }
          }

            /*
            Hoisting
            - Make each load store pair => cp.async
            - Get inductor variable register
            - for every cp
              - Get deps chain for load address register up until loop header
              - Get deps chain for store address register up until loop header

            Twice:
              -for every cp
                - Copy deps chains into preheader 
                  - change inductor variable to i
                  - if first time
                    - store addr unchanged
                  - else
                    - store addr + BLOCKSIZE ^ 2
              - cp.async.commit

            Loop Body
            - Add stage = inductor var % 2 
            - Add wait_group 1

            After 2nd Barrier
            - Add block 
              - branch if 2 + inductor var < loop limit
              - copy deps chain into block
              - change inductor variable usage to inductor_var + 2
              - increment store addr + stage * BLOCKSIZE^2
              - commit
            */
            errs()
              << "GOOD " << load_store_pairs.size() << "\n";
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