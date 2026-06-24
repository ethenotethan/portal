# Digest video `/v1/media` server bugs

Two distinct backend bugs in the digest-video media pipeline. Both are worked
around client-side in hermes-native; both should be fixed at the source.

---

## Bug 1 — `video_url` uses a hardcoded `localhost` host

**Status:** open (server-side) · **Client workaround:** `GatewayClient.resolvedMediaURL`

The digest pipeline stamps `video_url` (and `thumbnail_url` / `image_url`) with
a hardcoded **`http://localhost:8642/v1/media/…`** base instead of the request's
public host. A client connected to a *remote* gateway therefore receives an
unreachable loopback URL: the download gets `Connection refused`, and the player
hangs forever on "Loading…".

```console
# app is connected to https://gateway.model-optimizors.com (works, 200)
# but the feed item's video_url is:
http://localhost:8642/v1/media/researchoors_digest_final.mp4   ← unreachable from the client
```

**Fix:** build media URLs from the inbound request's host (or a configured
public base URL), not a hardcoded `localhost:<port>`.

**Client workaround:** `resolvedMediaURL` rewrites loopback media hosts
(`localhost`/`127.0.0.1`/`::1`) to the connected gateway's host before playback.

---

## Bug 2 — `/v1/media` HTTP Range off-by-one

**Status:** open (server-side) · **Client workaround:** `VideoCache` (download-then-play)

The gateway endpoint that serves digest videos — `/v1/media/*` on
`gateway.model-optimizors.com` — has an **off-by-one in its HTTP `Range`
handling**: it treats the range *end* as exclusive when RFC 7233 defines it as
**inclusive**. Every ranged request returns one byte too few, and `bytes=0-0`
returns `416` instead of the first byte.

This breaks streaming playback in hermes-native: `AVPlayer` fetches media via
range requests, gets the wrong byte counts back, and aborts with CoreMedia
error **`-12939`** ("Operation Stopped" — the slashed-out play button on
macOS). `VideoCache` works around it by downloading the whole file with a
single non-ranged `GET`, but that's a stopgap (no progressive playback; large
digests stall while the full file downloads).

> The `/v1/media` handler is **not** in the public `researchoors/hermes-agent`
> repo (verified across all branches + full history — only `/v1/files/...`
> exists, via aiohttp `web.FileResponse`). The response etag format
> (`<hex-mtime>-<hex-size>`) + `accept-ranges: bytes` suggest a static file
> server / CDN origin behind Cloudflare. The fix likely belongs in that origin
> config, not app code. GitHub issues + discussions are disabled on the repo,
> so this report lives here for routing to whoever owns the media service.

## Reproduction

Against `researchoors_digest_final.mp4` (size 20,415,444 bytes):

| Request `Range:` | Correct | Actual |
|---|---|---|
| *(none)* | `200`, len 20415444 | `200`, len 20415444 ✅ |
| `bytes=0-1` (2 bytes) | `206`, `bytes 0-1/…`, len 2 | `206`, `bytes 0-0/…`, **len 1** ❌ |
| `bytes=0-9` (10 bytes) | `206`, `bytes 0-9/…`, len 10 | `206`, `bytes 0-8/…`, **len 9** ❌ |
| `bytes=100-199` (100 bytes) | `206`, `bytes 100-199/…`, len 100 | `206`, `bytes 100-198/…`, **len 99** ❌ |
| `bytes=0-0` (first byte) | `206`, len 1 | **`416` Range Not Satisfiable** ❌ |

```console
$ URL=https://gateway.model-optimizors.com/v1/media/researchoors_digest_final.mp4
$ curl -sS -D - -o /dev/null -H "Range: bytes=0-1" "$URL"
HTTP/2 206
content-range: bytes 0-0/20415444
content-length: 1            # ← should be 2

$ curl -sS -D - -o /dev/null -H "Range: bytes=0-0" "$URL"
HTTP/2 416                    # ← should be 206 with 1 byte
```

## Root cause

The handler slices end-exclusive — `data[start:end]` — and computes
`Content-Length = end - start`. HTTP byte ranges are **inclusive on both ends**.

## Fix

For a parsed `Range: bytes=start-end`:

```python
# end is INCLUSIVE per RFC 7233
length = end - start + 1
chunk  = data[start:end + 1]
resp.headers["Content-Range"]  = f"bytes {start}-{end}/{total}"
resp.headers["Content-Length"] = str(length)
resp.set_status(206)
```

- `bytes=0-0` must return **1 byte** (status 206), not 416.
- `416` is only correct when `start >= total`.
- Honor open-ended (`bytes=start-`) and suffix (`bytes=-N`) forms too.

## After the fix

Once ranges are inclusive, hermes-native can stream digest videos directly
(point `AVPlayer` at the URL) and the `VideoCache` full-download workaround can
be deleted.
