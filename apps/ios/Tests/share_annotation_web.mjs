// The WEB's serializer over shapes the iOS share-viewer gate drew:
//
//   node apps/ios/Tests/share_annotation_web.mjs <raw-shapes.json>
//
// Prints serializeAnnotation(shapes).json (apps/web/src/lib/share/
// annotation.ts, imported as-is — Node strips its types). scripts/
// ios-share-viewer.sh compares it with the annotation the app POSTed, so a
// drawing made on the iPhone is proven to be the bytes the web would send.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const web = fileURLToPath(new URL("../../web/src/lib/share/annotation.ts", import.meta.url));
const { serializeAnnotation } = await import(web);
const shapes = JSON.parse(readFileSync(process.argv[2], "utf8"));
const out = serializeAnnotation(shapes);
process.stdout.write((out.json ?? "null") + "\n");
