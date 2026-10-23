// Types of storehouse/client (storehouse-client.mjs).

export interface QueueOptions {
  /** The app's Storehouse.Plug.Presign. */
  presignUrl: string
  /** The app's Storehouse.Plug.Register. */
  registerUrl: string
  /** Sent with each request to the app: a CSRF token, an authorization. */
  headers?: Record<string, string>
  /** Uploads to the store at once. Default 4. */
  concurrency?: number
  /** Files presigned in one request, at most. Default 50. */
  presignBatchSize?: number
  /** Files registered in one request, at most. Default 10. */
  registerBatchSize?: number
  /** How long a finished upload waits for others to register with. Default 400 ms. */
  registerMaxWaitMs?: number
  /** Tries again after a network error or the store's 5xx. Default 2. */
  retries?: number
  /** Read each file's SHA-256 to find the files the app has. Default true. */
  checksum?: boolean
  /** Files larger than this are not read for their checksum. Default 512 MiB. */
  checksumMaxBytes?: number
  /** The app's Storehouse.Plug.Multipart: large files go in parts through it. */
  multipartUrl?: string
  /** Files of this size or more go in parts, with multipartUrl. Default 100 MiB. */
  multipartThreshold?: number
  /** Parts of one file sent at once. Default 4. */
  partConcurrency?: number
  /** Tries again for each part, after a network error or a 5xx. Default 3. */
  partRetries?: number
  /** Where an upload in parts is remembered across reloads. Default localStorage; null for nowhere. */
  storage?: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null
  /** In place of fetch: a JSON POST to the app, giving its answer. */
  fetch?: (url: string, body: unknown) => Promise<any>
  /** In place of XMLHttpRequest: the browser's PUT to the store. */
  put?: (
    signed: SignedUpload,
    file: Blob,
    onProgress: (fraction: number) => void,
    signal: AbortSignal
  ) => Promise<void>
}

export interface SignedUpload {
  key: string
  method: string
  url: string
  headers: Record<string, string>
}

export type UploadStatus =
  | "pending"
  | "uploading"
  | "uploaded"
  | "registered"
  | "existing"
  | "error"
  | "cancelled"

export type UploadResult =
  /** The app's JSON for the file, as its Register plug gave it. */
  | { status: "registered"; value: any }
  /** A file the app has already: not uploaded. */
  | { status: "existing"; value: any }
  /** A code to say in the app's own words: not_accepted, too_large, storage_full, … */
  | { status: "error"; error: string }
  | { status: "cancelled" }

export interface Upload {
  readonly file: File | Blob
  readonly status: UploadStatus
  /** Its key in the store, once presigned. */
  readonly key: string | null
  /** How much is sent, from 0 to 1. */
  readonly fraction: number
  readonly result: Promise<UploadResult>
  onProgress(fn: (fraction: number) => void): void
  cancel(): void
}

export interface UploadQueue {
  add(file: File | Blob): Upload
  add(files: FileList | Iterable<File | Blob>): Upload[]
  on(
    event: "progress" | "uploaded" | "registered" | "existing" | "error" | "cancelled",
    fn: (upload: Upload, detail?: any) => void
  ): () => void
}

export function createUploadQueue(options: QueueOptions): UploadQueue
/** The SHA-256 of a file, in hex, or null where the browser cannot read it. */
export function checksum(file: Blob): Promise<string | null>
/** An image's width and height, as the browser draws it, or null. */
export function dimensions(file: Blob): Promise<{ width: number; height: number } | null>
