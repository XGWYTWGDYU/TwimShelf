// How the front end reaches the core: the TwimShelf server's HTTP interface (server/src/main.rs).
// One call = `POST /api/call/<name>` with the arguments as a JSON array; the answer is
// `{"r": <result>}`, the result as the core's C function returns it. The web page uses the page's
// own origin; the Electron app points it at its local server (with that server's token).

export class RemoteError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export interface Transport {
  call(name: string, args: unknown[]): Promise<unknown>;
  /** Where the server's own routes (/f/…, /api/scaled, …) are, '' for the page's origin. */
  readonly base: string;
}

export interface HttpOptions {
  base?: string;
  /** Extra headers on every request (the Electron app's token). */
  headers?: Record<string, string>;
  /** Called on 401: the sign-in ran out or the password changed. */
  onSignedOut?: () => void;
}

export function httpTransport(options: HttpOptions = {}): Transport {
  const base = options.base ?? '';
  return {
    base,
    async call(name, args) {
      const res = await globalThis.fetch(`${base}/api/call/${name}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...options.headers },
        body: JSON.stringify(args),
        credentials: 'same-origin',
      });
      const text = await res.text();
      if (res.status === 200) return (JSON.parse(text) as { r: unknown }).r;
      if (res.status === 401) {
        options.onSignedOut?.();
        throw new RemoteError(401, 'server.unauthorized');
      }
      throw new RemoteError(res.status, text || `HTTP ${res.status}`);
    },
  };
}
