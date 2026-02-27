import * as assert from "assert";
import { ApusClient } from "../src/apus-client";
import { ScreenshotFrame } from "../src/types";

type TestSocket = {
  readyState: number;
  close: () => void;
  closeCalled?: boolean;
};

type ApusClientInternals = ApusClient & {
  ws: TestSocket | null;
  state: "disconnected" | "connecting" | "connected";
  shouldReconnect: boolean;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
  handleDisconnect: (ws: TestSocket) => void;
};

describe("ApusClient", () => {
  describe("handleBinaryMessage", () => {
    it("parses [4-byte LE seq][JPEG] correctly", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      const frames: ScreenshotFrame[] = [];
      client.on("screenshotFrame", (f: ScreenshotFrame) => frames.push(f));

      // Build a binary frame: seq=42 (LE), then some fake JPEG data
      const buf = Buffer.alloc(4 + 6);
      buf.writeUInt32LE(42, 0);
      buf.write("JPEG01", 4);

      client.handleBinaryMessage(buf);

      assert.strictEqual(frames.length, 1);
      assert.strictEqual(frames[0].sequenceNumber, 42);
      assert.strictEqual(frames[0].jpegData.toString(), "JPEG01");
      client.dispose();
    });

    it("handles large sequence numbers (wrapping)", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      const frames: ScreenshotFrame[] = [];
      client.on("screenshotFrame", (f: ScreenshotFrame) => frames.push(f));

      const buf = Buffer.alloc(4 + 1);
      buf.writeUInt32LE(0xfffffffe, 0);
      buf[4] = 0xff;

      client.handleBinaryMessage(buf);

      assert.strictEqual(frames.length, 1);
      assert.strictEqual(frames[0].sequenceNumber, 0xfffffffe);
      client.dispose();
    });

    it("ignores frames smaller than 5 bytes", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      const frames: ScreenshotFrame[] = [];
      client.on("screenshotFrame", (f: ScreenshotFrame) => frames.push(f));

      client.handleBinaryMessage(Buffer.alloc(4)); // Only header, no data
      assert.strictEqual(frames.length, 0);

      client.handleBinaryMessage(Buffer.alloc(0)); // Empty
      assert.strictEqual(frames.length, 0);
      client.dispose();
    });
  });

  describe("state management", () => {
    it("starts in disconnected state", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      assert.strictEqual(client.getState(), "disconnected");
      assert.strictEqual(client.getServerInfo(), null);
      client.dispose();
    });

    it("connect on disposed client is a no-op", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      client.dispose();
      // Should not throw
      client.connect();
      assert.strictEqual(client.getState(), "disconnected");
    });

    it("disconnect resets to disconnected", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      client.disconnect();
      assert.strictEqual(client.getState(), "disconnected");
      client.dispose();
    });
  });

  describe("callTool", () => {
    it("rejects when not connected", async () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      await assert.rejects(
        () => client.callTool("get_logs"),
        /Not connected/
      );
      client.dispose();
    });
  });

  describe("subscribe/unsubscribe", () => {
    it("tracks active channels without throwing when disconnected", async () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      // Should not throw — just queues for reconnect
      await client.subscribe(["logs", "screenshots"]);
      await client.unsubscribe(["logs"]);
      client.dispose();
    });
  });

  describe("updateConfig", () => {
    it("updates host and port", () => {
      const client = new ApusClient("127.0.0.1", 9848, 5000);
      // Should not throw when disconnected
      client.updateConfig("192.168.1.100", 9999, 3000);
      client.dispose();
    });
  });

  describe("reconnect lifecycle", () => {
    it("manual disconnect disables auto-reconnect", () => {
      const client = new ApusClient(
        "127.0.0.1",
        9848,
        5000
      ) as unknown as ApusClientInternals;
      const ws: TestSocket = {
        readyState: 1,
        closeCalled: false,
        close() {
          this.closeCalled = true;
        },
      };

      client.ws = ws;
      client.state = "connected";
      client.disconnect();

      assert.strictEqual(ws.closeCalled, true);
      assert.strictEqual(client.shouldReconnect, false);
      assert.strictEqual(client.reconnectTimer, null);
      assert.strictEqual(client.getState(), "disconnected");
      client.dispose();
    });

    it("ignores close events from stale sockets", () => {
      const client = new ApusClient(
        "127.0.0.1",
        9848,
        5000
      ) as unknown as ApusClientInternals;
      const staleWs: TestSocket = { readyState: 1, close() {} };
      const activeWs: TestSocket = { readyState: 1, close() {} };

      client.ws = activeWs;
      client.state = "connected";
      client.handleDisconnect(staleWs);

      assert.strictEqual(client.ws, activeWs);
      assert.strictEqual(client.getState(), "connected");
      assert.strictEqual(client.reconnectTimer, null);
      client.dispose();
    });
  });
});
