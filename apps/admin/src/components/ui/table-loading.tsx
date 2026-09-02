/**
 * The one loading state for an admin table's contents. Three tables carried a
 * byte-identical copy of this line; they now share it.
 */
export function TableLoading() {
  return <p className="text-sm text-muted-foreground">Loading…</p>;
}
