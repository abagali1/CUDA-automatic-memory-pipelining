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
#include <unordered_set>
#include <unordered_map>

/* *******Implementation Ends Here******* */

using namespace llvm;

namespace {
  struct HW2CorrectnessPass : public PassInfoMixin<HW2CorrectnessPass> {

    PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM) {
      llvm::BlockFrequencyAnalysis::Result &bfi = FAM.getResult<BlockFrequencyAnalysis>(F);
      llvm::BranchProbabilityAnalysis::Result &bpi = FAM.getResult<BranchProbabilityAnalysis>(F);
      llvm::LoopAnalysis::Result &li = FAM.getResult<LoopAnalysis>(F);
      /* *******Implementation Starts Here******* */
      // Your core logic should reside here.

      for(Loop *L: li){
        auto blocks = L->getBlocks();
        std::unordered_set<BasicBlock*> freq_path;
        std::unordered_set<BasicBlock*> infreq_path(blocks.begin(), blocks.end());

        BasicBlock *header = L->getHeader();
        BasicBlock *cur_block = header;

        freq_path.insert(header);
        infreq_path.erase(header);
        do{
          Instruction &term = cur_block->back();

          if(term.getNumSuccessors() > 1){
            BasicBlock *left = term.getSuccessor(0);
            BasicBlock *right = term.getSuccessor(1);
            auto p = bpi.getEdgeProbability(cur_block, left);

            if(p >= BranchProbability(4, 5)){ // left frequent
              cur_block = left;
              freq_path.insert(left);
              infreq_path.erase(left);
            }else if(p <= BranchProbability(1, 5)){ // right frequent
              cur_block = right;
              freq_path.insert(right);
              infreq_path.erase(right);
            }else{ // neither frequent
              break;
            }
          }else{
            freq_path.insert(cur_block);
            infreq_path.erase(cur_block);
            cur_block = cur_block->getUniqueSuccessor();
          }
        }while(cur_block != header);

        std::unordered_set<Instruction*> freq_load, freq_store, infreq_store;
        for(BasicBlock *b: freq_path){
          for(Instruction &i: *b){
            auto opcode = i.getOpcode();
            if(opcode == Instruction::Load){
              freq_load.insert(&i);
            }else if(opcode == Instruction::Store){
              freq_store.insert(&i);
            }
          }
        }
        for(BasicBlock *b: infreq_path){
          for(Instruction &i: *b){
            auto opcode = i.getOpcode();
            if(opcode == Instruction::Store){
              infreq_store.insert(&i);
            }
          }
        }

        for(Instruction *freq_load_inst: freq_load){
          auto load_addr = freq_load_inst->getOperand(0);
          if(!L->isLoopInvariant(load_addr)){
            continue;
          }

          bool invariant = true;
          for(Instruction *freq_store_inst: freq_store){
            auto store_addr = freq_store_inst->getOperand(1);
            if(store_addr == load_addr){
              invariant = false;
              break;
            }
          }
          if(!invariant){
            continue;
          }

          freq_load_inst->moveBefore(&L->getLoopPreheader()->back());

          SSAUpdater ssa_updater;
          ssa_updater.Initialize(freq_load_inst->getType(), freq_load_inst->getName());
          ssa_updater.AddAvailableValue(freq_load_inst->getParent(), freq_load_inst);

          for(Instruction *infreq_store_inst: infreq_store){
            auto store_addr = infreq_store_inst->getOperand(1);
            if(store_addr == load_addr){
              Instruction *load_fix_up = freq_load_inst->clone();
              load_fix_up->insertAfter(infreq_store_inst);
              ssa_updater.AddAvailableValue(infreq_store_inst->getParent(), load_fix_up);
            }
          }

          std::unordered_set<Use*> use_set;
          for(Use &use: freq_load_inst->uses()){
            use_set.insert(&use);
          }
          for(Use *use: use_set){
            ssa_updater.RewriteUse(*use);
          }
        }
      }

      /* *******Implementation Ends Here******* */
      // Your pass is modifying the source code. Figure out which analyses
      // are preserved and only return those, not all.
      return PreservedAnalyses::all();
    }
  };
  struct HW2PerformancePass : public PassInfoMixin<HW2PerformancePass> {
    PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM) {
      llvm::BlockFrequencyAnalysis::Result &bfi = FAM.getResult<BlockFrequencyAnalysis>(F);
      llvm::BranchProbabilityAnalysis::Result &bpi = FAM.getResult<BranchProbabilityAnalysis>(F);
      llvm::LoopAnalysis::Result &li = FAM.getResult<LoopAnalysis>(F);
      /* *******Implementation Starts Here******* */
      // This is a bonus. You do not need to attempt this to receive full credit.
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
            FPM.addPass(HW2CorrectnessPass());
            return true;
          }
          return false;
        }
      );
    }
  };
}