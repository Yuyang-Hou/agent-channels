export type InboundEnvelope = {
  channelId: string;
  messageId: number;
  from: string;
  text: string;
  receivedAt: number;
  untrusted: true;
};

export type DeliveryReceipt = {
  provider: string;
  providerDeliveryId?: string;
};

export type HostDelivery = (message: InboundEnvelope) => Promise<DeliveryReceipt>;

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
