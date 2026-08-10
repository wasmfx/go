(module $asm_wasm
  (type $ft0 (func (param) (result)))
  (type $ft1 (func (param i32) (result i32)))
  (type $ft2 (func (param i64) (result)))
  (type $ct1 (cont $ft0))
  (type $scheduler-context-ftype (func (param i32) (param (ref null $ct1))))
  (type $scheduler-context-ctype (cont $scheduler-context-ftype))

  (import "main" "table" (table $0 2 funcref))
  (import "main" "memory" (memory $0 2))
  (import "main" "SP" (global $SP (mut i32)))
  (import "main" "g" (global $g (mut i64)))
  (import "main" "mcall0" (func $mcall0 (type $ft1)))
  (import "main" "morestack" (func $morestack (type $ft1)))
  (import "main" "printNum" (func $printNum (type $ft2)))
  (table $contTable 1000 (ref null $ct1))

  (tag $gogo)
  (tag $scheduler)
  (tag $more-stack-tag)
  (tag $exit-scheduler-exn) ;; an exception that we throw to exit the scheduler and return out of mcall.
  (export "gogo" (tag $gogo))
  (export "scheduler" (tag $scheduler))
  (export "more-stack-tag" (tag $more-stack-tag))
  ;; (export "exit-scheduler" (tag $exit-scheduler))
  (elem declare func $invokinator)
  (elem declare func $resuminator)

  ;; This is the outermost trampoline, effectively replacing wasm_pc_f_loop. It
  ;; knows how to find and invoke a current continuation from the global g, or
  ;; dispatch based on a function index if there is no saved continuation.
  ;; Crucially, it also sets up a "scheduler context", namely a stack frame that
  ;; the scheduler can quickly exit to by throwing an exception (runtime.gogo does so).
  ;;
  ;; Note: resuminator is separated out conceptually, but it is only called from
  ;; here and could be inlined into scheduler_context.
  (func $scheduler_context (export "scheduler_context") (param) (result)
    (local $suspension (ref null $ct1))
    (local $g-index i32)  ;; this is the index of the prior g, which will tell us where to store the suspension that is created when a goroutine hits the scheduler code (mcall).

    (loop $continue (result)
        ;; Get the wasmfxContIndex from the global g structure.
        (global.get $g)
        (i32.wrap_i64)
        (i32.load offset=464)  ;; get wasmfxContIndex from g. 464 is the offset in the structure; fragile, obviously.
        (local.tee $g-index)

        (table.get $contTable)
        (local.set $suspension)

        ;; Set the current goroutine's continuation table entry to null. We don't want
        ;; to reinvoke that continuation, which is a runtime error.
        ;;
        ;; Presently, with PC_B/PC_F flow still in place, if we come around on
        ;; that g-index again, the null will trigger the invokinator instead of
        ;; the resume, which works fine. And this will happen if there are codepaths
        ;; in the runtime that set the function return value to 1 but which
        ;; haven't been integrated with the new suspend/resume code.
        (table.set $contTable (local.get $g-index) (ref.null $ct1))

        (block $gogo_handler (result)
            (try_table (result) (catch $exit-scheduler-exn $gogo_handler)
                (call $resuminator (local.get $g-index) (local.get $suspension))
            )
        )  ;; LABEL gogo_handler:
        ;; (br_if $continue (i32.eqz (global.get $PAUSE)))  ;; TODO: Check the PAUSE global (7)

        ;; Unconditionally loop around for now. Note that normal program exit happens through
        ;; a WASI call to proc_exit, not by returning through here.
        (br $continue)
    )

    ;; The wrapper function generated for scheduler_context will pop the stack for us.
    ;; Which is not what we want! So we decrement the stack here to offset what the
    ;; wrapper will do.
    (global.get 0)
    (i32.const 8)
    (i32.sub)
    (global.set 0)
  )

  ;; Resuminator sets up suspension handlers for the scheduler and morestack,
  ;; and then calls the continuation that was passed in. If there is no
  ;; continuation, it calls invokinator to start a new goroutine based on the PC_F
  ;; and PC_B values on the stack.
  (func $resuminator (param $g-index i32) (param $suspension (ref null $ct1)) (result)
      ;; Call the nominated continuation (in $suspension) or if we don't have
      ;; one, use invokinator to start something based on pc_f/pc_b.
      (if (ref.is_null (local.get $suspension))
        (then
          (local.set $suspension (cont.new $ct1 (ref.func $invokinator))))
      )
      (block $exit
        (block $more-stack-handler (result (ref null $ct1))
        (block $scheduler_handler (result (ref null $ct1))
          (resume $ct1
            ;; Note: The two handlers do almost the same thing, but one carries on by calling mcall0 and the other calls morestack.
            ;; Before stack-switching, those runtime functions had their own cheap way of capturing the stack, and simply carried
            ;; on with their own work (mcall0 or morestack). Now we need to use the suspend instruction to capture the stack, and
            ;; a corresponding handler to do whatever we were going to do next.
            (on $scheduler $scheduler_handler)
            (on $more-stack-tag $more-stack-handler)
            (local.get $suspension))
          (ref.null $ct1)
          (br $exit)
        )  ;; LABEL scheduler_handler:
        (local.set $suspension)
        ;; Store the continuation at the outgoing groutine's index in the continuation table.
        ;; invoke the continuation of the incoming groutine. Presently we're finding the prior
        ;; goroutine at the top of this function where it was in global $g and we don't need
        ;; to know the identity of the incoming goroutine.
        (local.get $g-index)
        (local.get $suspension)
        (table.set $contTable)

        ;; Push the PC_B for the call to $mcall0, namely 0. Probably $mcall0 could be compiled
        ;; w/o that convention but I don't know how. Anyway we plan to eliminate PC_B as a 
        ;; calling convention.
        (i32.const 0)
        (call $mcall0)  ;; is expected to throw to the $gogo_handler (using the $exit_scheduler exception tag).
        (unreachable)

        )  ;; LABEL more-stack-handler:
        (local.set $suspension)
        ;; store the continuation at the outgoing groutine's index in the continuation table.
        ;; invoke the continuation of the incoming groutine. Presently we're finding the prior
        ;; goroutine at the top of this function where it was in global $g and we don't need
        ;; to know the identity of the incoming goroutine.
        (local.get $g-index)
        (local.get $suspension)
        (table.set $contTable)
        ;; Push the PC_B for the call to $morestack, namely 0. Probably $morestack could be
        ;; compiled w/o that convention but I don't know how. Anyway we plan to eliminate PC_B
        ;; as a calling convention.
        (i32.const 0)
        (call $morestack)  ;; is expected to throw to the $gogo_handler (using the $exit_scheduler exception tag).
        (unreachable)
      )  ;; LABEL exit:
      (return)
  )

  ;; Used when the go runtime wants to actually throw away current stack and jump out of the
  ;; scheduler context. That has the effect of going around the trampoline to jump into the stack
  ;; of the next selected goroutine.
  (func $exit_scheduler (export "exit_scheduler")
    (throw $exit-scheduler-exn))

  ;; Invoke a function using PC_F & PC_B from the current stack pointer. This is
  ;; used when starting a new goroutine, or if the old control flow is triggered
  ;; (returning 1 from a function, without hitting mcall and using its `suspend`.)
  ;; The "old control flow" path is intended to be removed someday, along with
  ;; PC_B, but there will may always be a need for a generic stub that can start
  ;; any goroutine.
  (func $invokinator (export "invokinator")
    (local $debug1 i32)
    (local $debug2 i32)

    ;; Get the PC_B and the function index PC_F from the SP. The PC_B will go on the Wasm stack,
    ;; the PC_F will be the index in the indirect call table.
    (i32.load16_u (i32.sub (global.get $SP) (i32.const 8)))
    (local.tee $debug1)
    (i32.load offset=2 (i32.sub (global.get $SP) (i32.const 8)))
    (local.tee $debug2)
    (call_indirect (type $ft1))
    (drop)
    (return)
    (unreachable)
  )

;; The disassembly of the original wasm_pc_f_loop1, which was extracted from wasm_pc_f_loop.
;; That's now translated into invokinator above.
;;
;;  0x134fce | 18          | size of function
;;  0x134fcf | 00          | 0 local blocks
;;  0x134fd0 | 23 00       | global_get global_index:0
;;  0x134fd2 | 41 08       | i32_const value:8
;;  0x134fd4 | 6b          | i32_sub
;;  0x134fd5 | 2f 01 00    | i32_load16_u memarg:MemArg { align: 1, max_align: 1, offset: 0, memory: 0 }
;;  0x134fd8 | 23 00       | global_get global_index:0
;;  0x134fda | 41 08       | i32_const value:8
;;  0x134fdc | 6b          | i32_sub
;;  0x134fdd | 28 02 02    | i32_load memarg:MemArg { align: 2, max_align: 2, offset: 2, memory: 0 }
;;  0x134fe0 | 11 00 00    | call_indirect type_index:0 table_index:0
;;  0x134fe3 | 1a          | drop
;;  0x134fe4 | 0f          | return
;;  0x134fe5 | 00          | unreachable
;;  0x134fe6 | 0b          | end
)


;; ;; Wow: the AI wrote this just given the name.
;; (func $deleteContinuation (export "deleteContinuation")
;;   (local $g-index i32)
;;   (global.get $g)
;;   (i32.wrap_i64)
;;   (i32.load offset=464)  ;; get wasmfxContIndex from g
;;   (local.set $g-index)
;;   (table.set $contTable (local.get $g-index) (ref.null $ct1))
;; )