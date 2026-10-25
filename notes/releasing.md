# Releasing

How wabisabi's ISOs get from a git tag to [wabisabi.computer](https://wabisabi.computer). The routine part is one script, [`scripts/release.sh`](../scripts/release.sh); the rest of this note is the one-time Cloudflare setup it depends on, and why it is shaped the way it is.

## Where the downloads live

A Cloudflare R2 bucket, `wasisabi-releases` (the project's earlier name: R2 cannot rename a bucket, and only the domain is public), served at `https://downloads.wabisabi.computer` (a custom domain on the bucket), laid out as one folder per version plus an index:

```
v0.2.0/wabisabi-offline.iso      the live ISO, about 9 GB
v0.2.0/wabisabi-netinstall.iso   the text installer, about 1.6 GB
v0.2.0/SHA256SUMS
releases.json                    what is downloadable, newest first
```

The website reads `releases.json` in the browser, so publishing or deleting a version changes the site's download card without rebuilding the site. A version's files are never changed once written.

Why R2: downloads (egress) are free, storage is $0.015 per GB-month with 10 GB free, and GitHub releases cap a file at 2 GiB, which the live ISO is far over.

## One-time setup (Cloudflare dashboard)

The domain `wabisabi.computer` has to be on Cloudflare (its DNS, not necessarily its registration) and shown as **Active** there.

1. **Create the bucket.** R2 Object Storage (the first time, R2 has to be enabled, which asks for a payment method even on the free tier) → **Create bucket**: name `wasisabi-releases`, location Automatic, storage class Standard.
2. **Connect the download domain.** The bucket → **Settings** → **Custom Domains** → **Add** → `downloads.wabisabi.computer`. Cloudflare creates the DNS record itself; wait for **Active**. Leave the Public Development URL (`r2.dev`) disabled: it is rate-limited and meant for testing.
3. **Let the website read the index (CORS).** Same Settings page → **CORS Policy** → **Add**:

   ```json
   [
     {
       "AllowedOrigins": [
         "https://wabisabi.computer",
         "https://www.wabisabi.computer",
         "https://wighawag.github.io",
         "http://localhost:5173",
         "http://localhost:4791"
       ],
       "AllowedMethods": ["GET", "HEAD"]
     }
   ]
   ```

   The localhost entries are the website's dev server and preview. The same rules, in wrangler's format, are in [`scripts/release-cors.json`](../scripts/release-cors.json).
4. **An upload key.** R2 Object Storage → **Manage API tokens** → **Create Account API token**: permission **Object Read & Write**, **Apply to specific buckets only** → `wasisabi-releases`, and a short TTL if it is for one release. Keep three values: the **Access Key ID**, the **Secret Access Key** (shown once), and the **Account ID** (in the S3 endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`).
5. **Give them to the script**, in the environment or in `~/.config/wabisabi/r2.env` (then `chmod 600` it):

   ```sh
   R2_ACCOUNT_ID=...
   R2_ACCESS_KEY_ID=...
   R2_SECRET_ACCESS_KEY=...
   ```

The same setup with wrangler instead of the dashboard, once `wrangler login` has been run:

```sh
wrangler r2 bucket create wasisabi-releases
wrangler r2 bucket domain add wasisabi-releases --domain downloads.wabisabi.computer --zone-id <zone id of wabisabi.computer>
wrangler r2 bucket cors set wasisabi-releases --file scripts/release-cors.json
```

(The upload key is still made in the dashboard: wrangler cannot create one.)

## A release

```sh
git tag v0.2.0 && git push origin v0.2.0
scripts/release.sh publish 0.2.0 --dry-run   # builds, checksums, shows every upload and deletion
scripts/release.sh publish 0.2.0             # ... and does them
```

`publish`:

1. refuses a tag that is not on GitHub, then builds both ISOs from `github:wighawag/wabisabi/v0.2.0`, so what is published is what anyone can rebuild;
2. uploads them and a `SHA256SUMS` under `v0.2.0/` (rclone, multipart: a single R2 upload stops at 5 GiB);
3. puts the version first in `releases.json`;
4. **keeps only the newest version** (`--keep N` for more) and deletes the rest from the bucket;
5. writes the download links and checksums into the GitHub release's notes, creating the release if needed. That is a second channel: someone who could tamper with the bucket still could not make GitHub agree.
6. attaches the netinstall ISO and its `SHA256SUMS` line to the GitHub release (the offline ISO is over GitHub's 2 GiB asset limit), and starts the website's Pages workflow. The website's download card reads the bucket live, but until that answers, or if it never does (no CORS policy on the bucket, say), it shows a fallback baked in at build time: the netinstall ISO of the newest GitHub release carrying one. GitHub keeps it when the bucket deletes the version, so the fallback never points at a deleted file. Starting the workflow needs `gh` logged in with access to `wighawag/wabisabi-website`; if it fails, the release still stands and `gh workflow run pages.yml -R wighawag/wabisabi-website` does it by hand.

Other commands:

```sh
scripts/release.sh delete 0.1.0   # one version's folder and index entry
scripts/release.sh list           # the index, and what the bucket really holds
```

## Why only one version

Stealth mode: an offline ISO costs about $0.14 a month to keep, and nobody needs an old one yet. Nothing is lost by deleting, because the ISOs are reproducible from their tag: the netinstall ISO rebuilt from `v0.1.0` came out byte-identical (same SHA-256) to the one published before. `nix build github:wighawag/wabisabi/vX.Y.Z#iso-offline` brings any version back. When old versions start to matter, publish with `--keep 3` (or more).
