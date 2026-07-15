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
  (elem declare func $scheduler_context)

  ;; Misnomer: This function is now actually the scheduler-context, and the one by that name is the resume handler.
  (func $resuminator (export "resuminator") (param) (result)
    (local $suspension (ref null $ct1))
    (local $g-index i32)  ;; this is the index of the prior g, which will tell us where to store the suspension that is created when a goroutine hits the scheduler code (mcall).

    ;; Fetch the current g's wasmFxContIndex for use when we do table.set later.
    ;; We want the g object that we're coming in on. When we are suspended to the
    ;; resume handler, the global g will be the new target g as set by
    ;; runtime.gogo. But the continuation passed to that point will be the
    ;; continuation of the previous goroutine, i.e. the one we are activating now.
    ;; So we want to capture the context of the current g now in order to store ITS
    ;; continuation after the jump.
    (global.get $g) ;; get the global g structure
    (i32.wrap_i64)
    ;; (i32.load offset=448)  ;; get wasmfxContIndex from g
    (i32.load offset=464)  ;; get wasmfxContIndex from g    ;; ... offset seems to have changed
    (local.tee $g-index)

    (table.get $contTable)
    ;; Note here we're setting $suspension to the immediate continuation that we
    ;; are about to resume into, while at the resume handler we'll set it to the
    ;; new continuation that was captured at the suspend site. These should
    ;; correspond to successive suspensions of the same goroutine.
    (local.set $suspension)
    (table.set $contTable (local.get $g-index) (ref.null $ct1))  ;; if we come around on that g-index again, we should have a null which kicks in the invokinator instead.

    (block $exit (result)  ;; Can actually do loop or break, but need a way to exit eventually.
        ;; Call this continuation in a resume context with two handlers, $gogo and $scheduler.
        ;; The $gogo handler just stores the resulting continuation in an appropriate
        (block $gogo_handler (result)
            (try_table (result) (catch $exit-scheduler-exn $gogo_handler)
               (call $scheduler_context (local.get $g-index) (local.get $suspension))
            )
        )  ;; LABEL gogo_handler:
        (br $exit)
    )
    ;; LABEL exit:

    ;; the wrapper function generated for resuminator will pop the stack for us.
    ;; Which is not what we want! So we decrement the stack here to offset what the
    ;; wrapper will do.
    (global.get 0)
    (i32.const 8)
    (i32.sub)
    (global.set 0)
  )

  ;; Misnomer: This function is now actually the resume handler, and "resuminator" is actually the stack frame that holds the scheduler context. TODO: switch them
  (func $scheduler_context (param $g-index i32) (param $suspension (ref null $ct1)) (result)
      ;;(call $printNum (i64.extend_i32_u (local.get $g-index)))
      ;; Call the nominated continuation (in $suspension) or if we don't have one, use invokinator to start something based on pc_f/pc_b.
      (if (ref.is_null (local.get $suspension))
        (then
          (local.set $suspension (cont.new $ct1 (ref.func $invokinator))))
      )
      (block $exit
        (block $more-stack-handler (result (ref null $ct1))
        (block $scheduler_handler (result (ref null $ct1))
          (resume $ct1
            (on $scheduler $scheduler_handler)
            (on $more-stack-tag $more-stack-handler)
            (local.get $suspension))
          (ref.null $ct1)
          (br $exit)
        )  ;; LABEL scheduler_handler:
        (local.set $suspension)
        ;; store the continuation at the outgoing groutine's index in the continuation table.
        ;; invoke the continuation of the incoming groutine. Presently we're finding the prior
        ;; goroutine at the top of this function where it was in global $g and we don't need
        ;; to know the identity of the incoming goroutine.
        (local.get $g-index)
        (local.get $suspension)
        (table.set $contTable)

        (i32.const 0)   ;; The PC_B for the call to $mcall0. Probably $mcall0 could be compiled w/o that convention but I don't know how.
        (call $mcall0)  ;; is expected to suspend to the $gogo_handler
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
        (i32.const 0)   ;; The PC_B for the call to $morestack. Probably $morestack could be compiled w/o that convention but I don't know how.
        (call $morestack)  ;; is expected to suspend to the $gogo_handler
        (unreachable)
      )  ;; LABEL exit:
      (return)
  )

  (func $exit_scheduler (export "exit_scheduler")
    (throw $exit-scheduler-exn))

  (func $invokinator (export "invokinator")
    (local $debug1 i32)
    (local $debug2 i32)

    (i32.load16_u (i32.sub (global.get $SP) (i32.const 8)))
    (local.tee $debug1)
    (i32.load offset=2 (i32.sub (global.get 0) (i32.const 8)))
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