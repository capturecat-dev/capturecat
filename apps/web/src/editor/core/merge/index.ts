/**
 * Project history core (docs/project-history.md): three-way merge on raw
 * project.json, change-sets, change summaries. Pure — no model, no clock.
 */
export {
  canonicalJSON,
  canonicalNumber,
  fnv1a64Hex,
  jsonEqual,
  type AutoResolved,
  type ConflictKind,
  type Json,
  type JsonObject,
  type MergeConflict,
  type Side,
} from "./jsonMerge";
export { MERGE_POLICY, policyHash, policyJSON, settingsTabFor, type MergePolicy } from "./policy";
export { merge, type MergeChoices, type MergeResult } from "./projectMerge";
export {
  CHANGE_HEADER_MAX_BYTES,
  changeSetFromJSON,
  changeSetJSON,
  composeChangeSets,
  countsOf,
  decodeChangeHeader,
  diff,
  emptyChangeSet,
  encodeChangeHeader,
  isEmptyChangeSet,
  type ChangeCounts,
  type ChangeSet,
  type CollectionChange,
} from "./projectDiff";
export { countChanges, formatChangeSummary, SUMMARY_SEPARATOR } from "./changeSummary";
