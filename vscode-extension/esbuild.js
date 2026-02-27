const esbuild = require("esbuild");

const isWatch = process.argv.includes("--watch");

/** @type {import('esbuild').BuildOptions} */
const nodeBaseOptions = {
  bundle: true,
  platform: "node",
  target: "node18",
  sourcemap: true,
  external: ["vscode"],
  logLevel: "info",
};

/** @type {import('esbuild').BuildOptions} */
const webviewBaseOptions = {
  bundle: true,
  platform: "browser",
  target: "es2022",
  format: "iife",
  sourcemap: true,
  logLevel: "info",
};

async function main() {
  const extensionOptions = {
    ...nodeBaseOptions,
    entryPoints: ["src/extension.ts"],
    outfile: "dist/extension.js",
    format: "cjs",
  };

  const testOptions = {
    ...nodeBaseOptions,
    entryPoints: ["test/suite/index.ts"],
    outdir: "dist/test/suite",
    format: "cjs",
  };

  const testFileOptions = {
    ...nodeBaseOptions,
    entryPoints: ["test/apus-client.test.ts"],
    outdir: "dist/test",
    format: "cjs",
  };

  const livePreviewWebviewOptions = {
    ...webviewBaseOptions,
    entryPoints: ["src/webviews/live-preview.ts"],
    outfile: "dist/webviews/live-preview.js",
  };

  const logViewerWebviewOptions = {
    ...webviewBaseOptions,
    entryPoints: ["src/webviews/log-viewer.ts"],
    outfile: "dist/webviews/log-viewer.js",
  };

  const inspectorWebviewOptions = {
    ...webviewBaseOptions,
    entryPoints: ["src/webviews/inspector-panel.ts"],
    outfile: "dist/webviews/inspector-panel.js",
  };

  if (isWatch) {
    const contexts = await Promise.all([
      esbuild.context(extensionOptions),
      esbuild.context(livePreviewWebviewOptions),
      esbuild.context(logViewerWebviewOptions),
      esbuild.context(inspectorWebviewOptions),
    ]);
    await Promise.all(contexts.map((ctx) => ctx.watch()));
    console.log("Watching extension and webview bundles for changes...");
  } else {
    await Promise.all([
      esbuild.build(extensionOptions),
      esbuild.build(testOptions),
      esbuild.build(testFileOptions),
      esbuild.build(livePreviewWebviewOptions),
      esbuild.build(logViewerWebviewOptions),
      esbuild.build(inspectorWebviewOptions),
    ]);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
