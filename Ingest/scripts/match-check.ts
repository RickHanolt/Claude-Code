// The matcher, against the exact pairs the broken version got wrong.
interface Seen { day: string; words: Set<string>; title: string; }
const describe = (e: { title: string; startDate: string }): Seen => ({
  day: e.startDate.slice(0, 10),
  words: new Set(e.title.toLowerCase().replace(/[^a-z0-9]+/g, " ").split(" ").filter((w) => w.length > 2)),
  title: e.title,
});
const overlap = (a: Seen, b: Seen) => {
  if (a.words.size === 0 || b.words.size === 0)
    return a.title.toLowerCase() === b.title.toLowerCase() ? 1 : 0;
  const dA = [...a.words].filter((w) => /\d/.test(w)).sort().join(" ");
  const dB = [...b.words].filter((w) => /\d/.test(w)).sort().join(" ");
  if (dA && dB && dA !== dB) return 0;
  let shared = 0;
  for (const w of a.words) if (b.words.has(w)) shared += 1;
  return shared / Math.min(a.words.size, b.words.size);
};
const T = 0.6;
const match = (x: string, y: string, day = "2026-09-16") =>
  overlap(describe({ title: x, startDate: day }), describe({ title: y, startDate: day })) >= T;

let bad = 0;
const ok = (n: string, c: boolean) => { if (!c) { bad++; console.error("FAIL " + n); } };

// The real pairs the old matcher scored as misses.
ok("Fall LEGO Club ~ LEGO Club", match("Fall LEGO Club", "LEGO Club"));
ok("Mass & BBQ ~ Mass and BBQ",
   match("Back to School Mass & BBQ", "Back to School Mass and BBQ"));
ok("wordier variant still matches",
   match("SMA Golf Outing 2026", "Golf Outing"));
ok("Siegel's permission slips",
   match("Siegel's Farm Field Trip Permission Slips Due", "Permission Slips Due - Siegel's Farm"));

// And it must still tell genuinely different things apart.
ok("Picture Day is not Pizza Day", !match("Picture Day", "Pizza Day"));
ok("K-3rd is not 4th-8th",
   !match("Basketball Skills Program K-3rd", "Basketball Skills Program 4th-8th"));
const findMatch = (n: Seen, h: Seen[]) => h.find((c) => c.day === n.day && overlap(n, c) >= T);
ok("different days never match",
   findMatch(describe({ title: "Picture Day", startDate: "2026-09-16" }),
             [describe({ title: "Picture Day", startDate: "2026-09-17" })]) === undefined);
ok("same day still matches",
   findMatch(describe({ title: "Picture Day", startDate: "2026-09-16" }),
             [describe({ title: "Fall Picture Day", startDate: "2026-09-16" })]) !== undefined);
ok("3:30 and 4:00 sessions stay distinct by grade",
   !match("Basketball Skills Program 4th-8th (3-4 PM)", "Basketball Skills Program K-3rd"));

console.log(bad === 0 ? "matcher: all checks passed" : `${bad} failed`);
process.exit(bad === 0 ? 0 : 1);
