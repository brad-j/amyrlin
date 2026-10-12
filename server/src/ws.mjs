// A minimal RFC 6455 WebSocket server endpoint on node:http, enough for the mock: text frames, ping/pong, close.
// No extensions (no permessage-deflate), no binary messages.
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** Completes the upgrade handshake on `socket` and returns a WebSocket, or null after refusing it. */
export function acceptUpgrade(request, socket) {
	const key = request.headers["sec-websocket-key"];
	if (request.headers.upgrade?.toLowerCase() !== "websocket" || typeof key !== "string") {
		socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
		return null;
	}
	const accept = createHash("sha1").update(key + GUID).digest("base64");
	socket.write(
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
			`Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
	);
	return new WebSocket(socket);
}

/** Emits "message" (string), "close" ({code, reason}). */
export class WebSocket extends EventEmitter {
	#socket;
	#buffer = Buffer.alloc(0);
	#fragments = [];
	#closed = false;
	#pingTimer;
	lastSeen = Date.now();

	constructor(socket) {
		super();
		this.#socket = socket;
		socket.setNoDelay(true);
		socket.on("data", (chunk) => this.#receive(chunk));
		socket.on("close", () => this.#finish(1006, "socket closed"));
		socket.on("error", () => this.#finish(1006, "socket error"));
		// Protocol section 2.3: the server pings every 15 s.
		this.#pingTimer = setInterval(() => this.#frame(0x9, Buffer.alloc(0)), 15_000);
	}

	get isOpen() {
		return !this.#closed;
	}

	send(text) {
		if (!this.#closed) this.#frame(0x1, Buffer.from(text, "utf8"));
	}

	/** Resolves once the socket's send buffer is below `limit` bytes, or the socket closed. */
	writable(limit = 8 * 1024 * 1024) {
		if (this.#closed || this.#socket.writableLength < limit) return Promise.resolve();
		return new Promise((resolve) => {
			const done = () => {
				this.#socket.off("drain", done);
				this.off("close", done);
				resolve();
			};
			this.#socket.on("drain", done);
			this.on("close", done);
		});
	}

	close(code = 1000, reason = "") {
		if (this.#closed) return;
		const payload = Buffer.alloc(2 + Buffer.byteLength(reason));
		payload.writeUInt16BE(code, 0);
		payload.write(reason, 2);
		this.#frame(0x8, payload);
		this.#socket.end();
		this.#finish(code, reason);
	}

	/** Breaks the connection without a close frame, as a network failure would. */
	destroy() {
		this.#socket.destroy();
		this.#finish(1006, "destroyed");
	}

	#finish(code, reason) {
		if (this.#closed) return;
		this.#closed = true;
		clearInterval(this.#pingTimer);
		this.emit("close", { code, reason });
	}

	#frame(opcode, payload) {
		if (this.#socket.destroyed) return;
		let header;
		if (payload.length < 126) {
			header = Buffer.from([0x80 | opcode, payload.length]);
		} else if (payload.length < 65_536) {
			header = Buffer.alloc(4);
			header[0] = 0x80 | opcode;
			header[1] = 126;
			header.writeUInt16BE(payload.length, 2);
		} else {
			header = Buffer.alloc(10);
			header[0] = 0x80 | opcode;
			header[1] = 127;
			header.writeBigUInt64BE(BigInt(payload.length), 2);
		}
		this.#socket.write(Buffer.concat([header, payload]));
	}

	#receive(chunk) {
		this.lastSeen = Date.now();
		this.#buffer = Buffer.concat([this.#buffer, chunk]);
		while (this.#buffer.length >= 2) {
			const first = this.#buffer[0];
			const second = this.#buffer[1];
			const fin = (first & 0x80) !== 0;
			const opcode = first & 0x0f;
			const masked = (second & 0x80) !== 0;
			let length = second & 0x7f;
			let offset = 2;
			if (length === 126) {
				if (this.#buffer.length < 4) return;
				length = this.#buffer.readUInt16BE(2);
				offset = 4;
			} else if (length === 127) {
				if (this.#buffer.length < 10) return;
				length = Number(this.#buffer.readBigUInt64BE(2));
				offset = 10;
			}
			const maskLength = masked ? 4 : 0;
			if (this.#buffer.length < offset + maskLength + length) return;
			const mask = masked ? this.#buffer.subarray(offset, offset + 4) : undefined;
			const payload = Buffer.from(this.#buffer.subarray(offset + maskLength, offset + maskLength + length));
			if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
			this.#buffer = this.#buffer.subarray(offset + maskLength + length);
			this.#handle(fin, opcode, payload);
		}
	}

	#handle(fin, opcode, payload) {
		switch (opcode) {
			case 0x0: // continuation
			case 0x1: // text
			case 0x2: // binary, treated as UTF-8 text
				this.#fragments.push(payload);
				if (fin) {
					const text = Buffer.concat(this.#fragments).toString("utf8");
					this.#fragments = [];
					this.emit("message", text);
				}
				break;
			case 0x8: {
				const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
				this.close(code === 1005 ? 1000 : code);
				break;
			}
			case 0x9:
				this.#frame(0xa, payload);
				break;
			case 0xa:
				break;
		}
	}
}
