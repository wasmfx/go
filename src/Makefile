ROOT?=/opt/wasmfx
BINARYEN?=$(ROOT)/binaryen
WASM_INTERP?=$(ROOT)/stack-switching/interpreter/wasm
WASM_MERGE=$(BINARYEN)/bin/wasm-merge --enable-nontrapping-float-to-int --enable-multimemory --enable-exception-handling --enable-reference-types --enable-multivalue --enable-bulk-memory --enable-gc --enable-stack-switching

BASELINE_GO=/usr/lib/go-1.25/bin/go

CUSTOM_GO_ROOT=/go/src
ASM_WASM_FILE=$(CUSTOM_GO_ROOT)/runtime/asm_wasm

$(ASM_WASM_FILE).wasm: $(ASM_WASM_FILE).wat
	$(WASM_INTERP) -d -i $< -o $@ > out.log

%.wasm: %.pre.wasm $(ASM_WASM_FILE).wasm
	$(WASM_MERGE) $(@:.wasm=.pre.wasm) "main" $(ASM_WASM_FILE).wasm "wasmfx" -o $@

%.pre.wasm: %.go
	GOOS=wasip1 GOARCH=wasm /go/bin/go build -o $@ $<

%-baseline.wasm: %.go
	GOTOOLCHAIN=local GOOS=wasip1 GOARCH=wasm $(BASELINE_GO) build -o $@ $<
