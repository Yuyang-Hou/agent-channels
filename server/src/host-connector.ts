export type InboundEnvelope = {
  channelId: string;
  messageId: number;
  from: string;
  source?: {
    provider: string;
    conversationId?: string;
    label?: string;
  };
  text: string;
  receivedAt: number;
  untrusted: true;
};

export type DeliveryReceipt = {
  provider: string;
  providerDeliveryId?: string;
};

export type HostDelivery = (message: InboundEnvelope) => Promise<DeliveryReceipt>;

const DEFAULT_CHANNEL_MESSAGE_TEMPLATE = [
  "> **↗ Agent Channels · 外部频道消息**",
  ">",
  "> **频道** `{channel_name}` · **来自** `{sender_name}` · `#{message_id}`",
  ">",
  "> {message_text}",
].join("\n");

export function formatChannelMessage(message: {
  channel: string;
  id: number;
  from: string;
  sourceLabel?: string;
  text: string;
}, template?: string): string {
  const safeInlineValue = (value: string) => value.replace(/[\r\n]+/g, " ").replaceAll("`", "ˋ");
  const values: Record<string, string> = {
    "{channel_name}": safeInlineValue(message.channel),
    "{message_id}": String(message.id),
    "{sender_name}": safeInlineValue(message.from),
    "{message_source}": safeInlineValue(message.sourceLabel?.trim() || message.from),
    "{message_text}": message.text.replace(/\r\n?/g, "\n"),
  };
  const source = (template || DEFAULT_CHANNEL_MESSAGE_TEMPLATE).replace(/\r\n?/g, "\n");
  return source.replace(
    /\{(?:channel_name|message_id|sender_name|message_source|message_text)\}/g,
    (key, offset: number) => {
      const value = values[key];
      const linePrefix = source.slice(source.lastIndexOf("\n", offset - 1) + 1, offset);
      const continuationPrefix = /^(?:[ \t]*>[ \t]?)+$/.test(linePrefix) ? linePrefix : "";
      return value.replaceAll("\n", `\n${continuationPrefix}`);
    },
  );
}

/** The Host may have accepted a mutating request, so automatic replay is unsafe. */
export class DeliveryOutcomeUnknownError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DeliveryOutcomeUnknownError";
  }
}

/** Keep one bound conversation ordered even if callers enqueue concurrently. */
export function serializeHostDelivery(deliver: HostDelivery): HostDelivery {
  let tail = Promise.resolve();
  return (message) => {
    const current = tail.then(() => deliver(message));
    tail = current.then(
      () => undefined,
      () => undefined,
    );
    return current;
  };
}
