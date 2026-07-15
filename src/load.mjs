// The `Wasi` class is taken from this blogpost with minor changes:
// https://dev.to/ndesmic/building-a-minimal-wasi-polyfill-for-browsers-4nel

export class Wasi {
	#argEncodedStrings;
	#envEncodedStrings;
	#fdFlags;
	#instance;

	constructor({ args, env }) {
		// encode args
		this.#argEncodedStrings = [];
		const safeArgs = Array.isArray(args) ? args : [];
		for (let i = 0; i < safeArgs.length; i++) {
			this.#argEncodedStrings.push(this.encodeCString(safeArgs[i]));
		}

		// Accept either an array of "KEY=VALUE" strings or an object.
		const safeEnv = Array.isArray(env)
			? env
			: (env && typeof env === "object"
				? Object.keys(env).map((key) => `${key}=${env[key]}`)
				: []);
		this.#envEncodedStrings = safeEnv.map((entry) => this.encodeCString(entry));
		this.#fdFlags = [0, 0, 0];

		this.bind();
	}

	// helper function to encode a string as a null-terminated C string in a Uint8Array
	encodeCString(s) {
		const str = String(s);
		const encoded = [];
		for (let i = 0; i < str.length; i++) {
			let codePoint = str.charCodeAt(i);
			if (codePoint >= 0xd800 && codePoint <= 0xdbff) {
				const low = str.charCodeAt(i + 1);
				if (low >= 0xdc00 && low <= 0xdfff) {
					codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (low - 0xdc00);
					i++;
				} else {
					codePoint = 0xfffd;
				}
			} else if (codePoint >= 0xdc00 && codePoint <= 0xdfff) {
				codePoint = 0xfffd;
			}

			if (codePoint <= 0x7f) {
				encoded.push(codePoint);
			} else if (codePoint <= 0x7ff) {
				encoded.push(0xc0 | (codePoint >> 6));
				encoded.push(0x80 | (codePoint & 0x3f));
			} else if (codePoint <= 0xffff) {
				encoded.push(0xe0 | (codePoint >> 12));
				encoded.push(0x80 | ((codePoint >> 6) & 0x3f));
				encoded.push(0x80 | (codePoint & 0x3f));
			} else {
				encoded.push(0xf0 | (codePoint >> 18));
				encoded.push(0x80 | ((codePoint >> 12) & 0x3f));
				encoded.push(0x80 | ((codePoint >> 6) & 0x3f));
				encoded.push(0x80 | (codePoint & 0x3f));
			}
		}
		encoded.push(0);
		return new Uint8Array(encoded);
	}

	set instance(val) {
		this.#instance = val;
	}

    bind(){
		this.clock_time_get = this.clock_time_get.bind(this);
		this.random_get = this.random_get.bind(this);
		this.environ_sizes_get = this.environ_sizes_get.bind(this);
		this.environ_get = this.environ_get.bind(this);
		this.fd_write = this.fd_write.bind(this);
		this.fd_fdstat_get = this.fd_fdstat_get.bind(this);
		this.fd_fdstat_set_flags = this.fd_fdstat_set_flags.bind(this);
		this.poll_oneoff = this.poll_oneoff.bind(this);
		this.args_get= this.args_get.bind(this);
		this.args_sizes_get = this.args_sizes_get.bind(this);
	}

	fd_write(fd, iovsPtr, iovsLength, bytesWrittenPtr) {
		const mem = new Uint8Array(this.#instance.exports.memory.buffer);
		const iovs = new Uint32Array(this.#instance.exports.memory.buffer, iovsPtr, iovsLength * 2);
		let text = "";
		let total = 0;
		// manually decoding bytes to string because TextDecoder isn't available in d8
		for (let i = 0; i < iovsLength * 2; i += 2) {
			const offset = iovs[i];
			const length = iovs[i + 1];
			for (let j = 0; j < length; j++) {
				text += String.fromCharCode(mem[offset + j]);
			}
			total += length;
		}

		new DataView(this.#instance.exports.memory.buffer).setInt32(bytesWrittenPtr, total, true);
		// d8's write() emits output without appending a newline.
		if (fd === 1 || fd === 2) write(text);
		return 0;
	}

	proc_exit(code) {
		if (code === 0) {
			quit(0);
		}
		throw new Error(`WASI exit with code ${code}`);
	}
	sched_yield() {
		throw new Error(`WASI sched_yield is not implemented`);
		return 0;
	}
    fd_close(fd) {
		throw new Error(`WASI fd_close is not implemented`);
        return 0;
    }
	fd_fdstat_get(fd, bufPtr) {
		const ERRNO_BADF = 8;
		const FILETYPE_CHARACTER_DEVICE = 2;
		const RIGHT_FD_READ = 1n << 1n;
		const RIGHT_FD_FDSTAT_SET_FLAGS = 1n << 3n;
		const RIGHT_FD_WRITE = 1n << 6n;
		const RIGHT_POLL_FD_READWRITE = 1n << 27n;

		if (fd !== 0 && fd !== 1 && fd !== 2) return ERRNO_BADF;

		let rights = RIGHT_FD_FDSTAT_SET_FLAGS | RIGHT_POLL_FD_READWRITE;
		rights |= fd === 0 ? RIGHT_FD_READ : RIGHT_FD_WRITE;

		const view = new DataView(this.#instance.exports.memory.buffer);
		view.setUint8(bufPtr, FILETYPE_CHARACTER_DEVICE);
		view.setUint8(bufPtr + 1, 0); // padding
		view.setUint16(bufPtr + 2, this.#fdFlags[fd], true);
		view.setUint32(bufPtr + 4, 0, true); // padding
		view.setBigUint64(bufPtr + 8, rights, true);
		view.setBigUint64(bufPtr + 16, 0n, true); // rights_inheriting
		return 0;
	}
    fd_seek(fd, offset, whence, newoffset) {
		throw new Error(`WASI fd_seek is not implemented`);
        return 0;
    }
	args_sizes_get(argCountPtr, argBufferSizePtr) {
		const argByteLength = this.#argEncodedStrings.reduce((sum, val) => sum + val.byteLength, 0);

		const countPointerBuffer = new Uint32Array(this.#instance.exports.memory.buffer, argCountPtr, 1);
		countPointerBuffer[0] = this.#argEncodedStrings.length;
		const sizePointerBuffer = new Uint32Array(this.#instance.exports.memory.buffer, argBufferSizePtr, 1);
		sizePointerBuffer[0] = argByteLength;

		return 0;
	}
	args_get(argsPtr, argBufferPtr) {
		const argsByteLength = this.#argEncodedStrings.reduce((sum, val) => sum + val.byteLength, 0);
		const argsPointerBuffer = new Uint32Array(this.#instance.exports.memory.buffer, argsPtr, this.#argEncodedStrings.length);
		const argsBuffer = new Uint8Array(this.#instance.exports.memory.buffer, argBufferPtr, argsByteLength)
		let pointerOffset = 0;
		for (let i = 0; i < this.#argEncodedStrings.length; i++) {
			const currentPointer = argBufferPtr + pointerOffset;
			argsPointerBuffer[i] = currentPointer;
			argsBuffer.set(this.#argEncodedStrings[i], pointerOffset)
			pointerOffset += this.#argEncodedStrings[i].byteLength;
		}
		return 0;
	}

	clock_time_get(clockId, precision, timePtr) {
		const time = BigInt(Date.now()) * 1000000n; // convert milliseconds to nanoseconds
		new DataView(this.#instance.exports.memory.buffer).setBigUint64(timePtr, time, true);
		return 0;
	}

	environ_get(environPtr, environBufferPtr) {
		const buffer = this.#instance.exports.memory.buffer;
		const pointers = new DataView(buffer);
		const bytes = new Uint8Array(buffer);
		let offset = 0;

		for (let i = 0; i < this.#envEncodedStrings.length; i++) {
			pointers.setUint32(environPtr + i * 4, environBufferPtr + offset, true);
			bytes.set(this.#envEncodedStrings[i], environBufferPtr + offset);
			offset += this.#envEncodedStrings[i].byteLength;
		}
		return 0;
	}

	environ_sizes_get(environCountPtr, environBufferSizePtr) {
		const envByteLength = this.#envEncodedStrings.reduce((sum, value) => sum + value.byteLength, 0);
		const view = new DataView(this.#instance.exports.memory.buffer);
		view.setUint32(environCountPtr, this.#envEncodedStrings.length, true);
		view.setUint32(environBufferSizePtr, envByteLength, true);
		return 0;
	}

	random_get(bufPtr, bufLen) {
		// throw new Error(`WASI random_get is not implemented`);
		const mem = new Uint8Array(this.#instance.exports.memory.buffer);
		for (let i = 0; i < bufLen; i++) {
			mem[bufPtr + i] = Math.floor(Math.random() * 256);
		}
		return 0;
	}

	// Written by Codex.
	poll_oneoff(inPtr, outPtr, nsubscriptions, neventsPtr) {
		// WASI preview1 subscription and event records are 48 and 32 bytes.
		// This polyfill has no real file-descriptor table, but clock events are
		// enough for runtimes which use poll_oneoff to sleep.
		const ERRNO_BADF = 8;
		const ERRNO_INVAL = 28;
		const EVENTTYPE_CLOCK = 0;
		const EVENTTYPE_FD_READ = 1;
		const EVENTTYPE_FD_WRITE = 2;
		const SUBSCRIPTION_CLOCK_ABSTIME = 1;
		const SUBSCRIPTION_SIZE = 48;
		const EVENT_SIZE = 32;

		if (nsubscriptions === 0) return ERRNO_INVAL;

		const view = new DataView(this.#instance.exports.memory.buffer);
		const nowNs = BigInt(Date.now()) * 1000000n;
		const subscriptions = [];
		let waitNs = null;

		for (let i = 0; i < nsubscriptions; i++) {
			const ptr = inPtr + i * SUBSCRIPTION_SIZE;
			const subscription = {
				userdata: view.getBigUint64(ptr, true),
				type: view.getUint8(ptr + 8),
				delayNs: 0n,
			};

			if (subscription.type === EVENTTYPE_CLOCK) {
				const timeout = view.getBigUint64(ptr + 24, true);
				const flags = view.getUint16(ptr + 40, true);
				subscription.delayNs = (flags & SUBSCRIPTION_CLOCK_ABSTIME)
					? (timeout > nowNs ? timeout - nowNs : 0n)
					: timeout;
				if (waitNs === null || subscription.delayNs < waitNs) {
					waitNs = subscription.delayNs;
				}
			} else if (subscription.type !== EVENTTYPE_FD_READ && subscription.type !== EVENTTYPE_FD_WRITE) {
				return ERRNO_INVAL;
			}
			subscriptions.push(subscription);
		}

		// An unsupported fd is immediately ready with BADF, so it takes priority
		// over a clock timeout. Atomics.wait provides a synchronous sleep in d8.
		const hasFdEvent = subscriptions.some((subscription) => subscription.type !== EVENTTYPE_CLOCK);
		if (!hasFdEvent && waitNs !== null && waitNs > 0n) {
			const waitMs = Number((waitNs + 999999n) / 1000000n);
			if (typeof Atomics !== "undefined" && typeof Atomics.wait === "function") {
				Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, waitMs);
			} else {
				const end = Date.now() + waitMs;
				while (Date.now() < end) { /* synchronous fallback */ }
			}
		}

		let eventCount = 0;
		for (const subscription of subscriptions) {
			if (subscription.type === EVENTTYPE_CLOCK && subscription.delayNs > (waitNs ?? 0n)) continue;
			if (hasFdEvent && subscription.type === EVENTTYPE_CLOCK) continue;

			const ptr = outPtr + eventCount * EVENT_SIZE;
			view.setBigUint64(ptr, subscription.userdata, true);
			view.setUint16(ptr + 8, subscription.type === EVENTTYPE_CLOCK ? 0 : ERRNO_BADF, true);
			view.setUint8(ptr + 10, subscription.type);
			view.setBigUint64(ptr + 16, 0n, true);
			view.setUint16(ptr + 24, 0, true);
			eventCount++;
		}

		view.setUint32(neventsPtr, eventCount, true);
		return 0;
	}

	fd_fdstat_set_flags(fd, flags) {
		const ERRNO_BADF = 8;
		const ERRNO_INVAL = 28;
		const VALID_FLAGS = 0x1f; // APPEND, DSYNC, NONBLOCK, RSYNC, SYNC

		if (fd !== 0 && fd !== 1 && fd !== 2) return ERRNO_BADF;
		if ((flags & ~VALID_FLAGS) !== 0) return ERRNO_INVAL;

		this.#fdFlags[fd] = flags;
		return 0;
	}

	fd_prestat_get(fd, bufPtr) {
		// This harness does not expose any preopened directories.
		return 8; // ERRNO_BADF
	}

	fd_prestat_dir_name() {
		throw new Error(`WASI fd_prestat_dir_name is not implemented`);
		return 0;
	}
}

// load the wasm file
const binary = readbuffer(arguments[0]);
const wasi = new Wasi({
    args: arguments
});

WebAssembly.instantiate(binary, { "wasi_snapshot_preview1": wasi }).then(({ instance }) => {
  wasi.instance = instance;
  instance.exports._start();
});
