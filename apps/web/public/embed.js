/**
 * CaptureCat script embed.
 *
 *   <script async src="https://capturecat.so/embed.js" data-capturecat-id="VIDEO_ID"></script>
 *
 * Replaces itself with a responsive 16:9 iframe of /embed/VIDEO_ID. Multiple
 * tags on one page each embed their own video. No dependencies, no globals.
 */
(function () {
  var script = document.currentScript;
  if (!script) return;
  var id = script.getAttribute("data-capturecat-id");
  if (!id || !/^[A-Za-z0-9_-]{4,64}$/.test(id)) return;

  var wrapper = document.createElement("div");
  wrapper.style.cssText =
    "position:relative;width:100%;aspect-ratio:16/9;border-radius:12px;overflow:hidden;background:#000;";

  var frame = document.createElement("iframe");
  frame.src = "https://capturecat.so/embed/" + encodeURIComponent(id);
  frame.title = "CaptureCat video";
  frame.loading = "lazy";
  frame.allow = "fullscreen";
  frame.allowFullscreen = true;
  frame.style.cssText =
    "position:absolute;inset:0;width:100%;height:100%;border:0;";

  wrapper.appendChild(frame);
  script.parentNode.insertBefore(wrapper, script);
})();
