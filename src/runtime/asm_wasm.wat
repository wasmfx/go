(module $asm_wasm
  (type $ft0 (func (param) (result)))
  (type $ft1 (func (param i32) (result i32)))
  (type $ft2 (func (param i64) (result)))
;;   (type $ft1 (func (param i32) (result i32)))
  (type $ct1 (cont $ft0))
  (import "main" "table" (table $0 2 funcref))
  (import "main" "memory" (memory $0 2))
  (import "main" "SP" (global $SP (mut i32)))
  (import "main" "g" (global $g (mut i64)))
  (import "main" "printNum" (func $printNum (type $ft2)))
  (table $contTable 1000 (ref null $ct1))

;;   (import "main" "wasm_pc_f_loop" (func $wasm_pc_f_loop (type $ft0)))
;;   (func $wasm_pc_f_loop (import "main" "wasm_pc_f_loop") (type $ft0))
;;   (import "main" "wasm_pc_f_loop2" (func $wasm_pc_f_loop2 (type $ft0)))
  (tag $yield)
  (export "yield" (tag $yield))
;;   (func $wasm_pc_f_loop (export "wasm_pc_f_loop") (param) (result) )
  (elem declare func $wasm_pc_f_loop2)
;;   (func $wasm_pc_f_loop2 (export "wasm_pc_f_loop2") (param) (result) )

  (func $resuminator (export "resuminator") (param) (result)
    (local $suspension (ref null $ct1))
    (local $idx1 i32)
    (local $idx2 i32)

    ;; Fetch the current g's wasmFxContIndex for use when we do table.set later.
    ;; We want the g object that we're coming in on. When we are suspended to the
    ;; resume handler, the global g will be the new target g as set by
    ;; runtime.gogo. But the continuation passed to that point will be the
    ;; continuation of the previous goroutine, i.e. the one we are activating now.
    ;; So we want to capture the context of the current g now in order to store ITS
    ;; continuation after the jump.
    (global.get $g) ;; get the global g structure
    (i32.wrap_i64)
    (i32.load offset=448)  ;; get wasmfxContIndex from g
    (local.tee $idx1)

    (table.get $contTable)
    ;; Note here we're setting $suspension to the immediate continuation that we
    ;; are about to resume into, while at the resume handler we'll set it to the
    ;; new continuation that was captured at the suspend site. These should
    ;; correspond to successive suspensions of the same goroutine.
    (local.set $suspension)

    ;; Call wasm_pc_f_loop2 in a resume context with a $yield handler that just
    ;; ignores the yielded continuation and returns.
    (block $on_yield (result (ref null $ct1))

        (if (ref.is_null (local.get $suspension))
          (then (local.set $suspension (cont.new $ct1 (ref.func $wasm_pc_f_loop2))))
        )

        ;;(cont.new $ct1 (ref.func $wasm_pc_f_loop2))
        (resume $ct1 (on $yield $on_yield) (local.get $suspension))
        (ref.null $ct1)   ;; A dummy for the continuation value that would be given if we had suspended.
    )
    (local.set $suspension)

    ;; store the continuation at the outgoing groutine's index in the continuation table.
    ;; invoke the continuation of the incoming groutine. Presently we're finding the prior
    ;; goroutine at the top of this function where it was in global $g and we don't need
    ;; to know the identity of the incoming goroutine.

    (local.get $idx1)
    (local.get $suspension)
    (table.set $contTable)

    ;; HACK SUPER HACK
    ;; the wrapper function generated for resuminator will pop the stack for us.
    ;; Which is not what we want! So we decrement the stack here to offset what the
    ;; wrapper will do.
    (global.get 0)
    (i32.const 8)
    (i32.sub)
    (global.set 0)
  )

  (func $wasm_pc_f_loop2 (export "wasm_pc_f_loop2")
    (local $debug1 i32)
    (local $debug2 i32)

    ;; (global.get 0)
    ;; (i64.extend_i32_s)
    ;; (call $printNum)

    ;; (i64.load (global.get 0))
    ;; (call $printNum)

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
;; That's now translated into wasm_pc_f_loop2 above.
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
