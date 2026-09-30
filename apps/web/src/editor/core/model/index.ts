/**
 * Lossless project model — see ../../ARCHITECTURE.md ("Lossless project.json").
 *
 *   const project = parseProject(JSON.parse(text));   // Swift init(from:) semantics
 *   const json = serializeProject(project);            // Swift encode(to:) + unknown keys
 */
export * from "./enums";
export type * from "./types";
export { ProjectDecodeError } from "./codec";
export { parseProject, parseProjectText } from "./parse";
export { serializeProject, serializeProjectText, ProjectEncodeError, type SerializeOptions } from "./serialize";
export * from "./defaults";
