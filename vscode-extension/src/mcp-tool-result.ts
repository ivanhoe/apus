function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function extractToolResultText(result: unknown): string {
  if (isRecord(result) && Array.isArray(result.content)) {
    const lines = result.content
      .filter((item) => isRecord(item) && item.type === "text" && typeof item.text === "string")
      .map((item) => item.text as string);

    if (lines.length > 0) {
      return lines.join("\n");
    }
  }

  return JSON.stringify(result);
}

export function isToolResultError(result: unknown): boolean {
  return isRecord(result) && result.isError === true;
}
