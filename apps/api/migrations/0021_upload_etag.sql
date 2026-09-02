-- ETag of the object verified at /complete. A presigned PUT stays valid for
-- its TTL after completion, so the byte route refuses an object whose ETag no
-- longer matches — a swapped file cannot be served under a verified record.
ALTER TABLE shared_videos ADD COLUMN etag TEXT;
