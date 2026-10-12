'use strict';
// Simulates two phones editing one shared-pad item; phone A's clock runs 1h fast.
const merge = (a, b) => (b.t > a.t ? b : b.t < a.t ? a : (b.by > a.by ? b : a));
function run(bump) {
  const A = { item: null }, B = { item: null };
  const clockA = (now) => now + 3600_000, clockB = (now) => now;
  const edit = (dev, by, now, clock, text) => {
    let t = clock(now);
    if (bump && dev.item) t = Math.max(t, dev.item.t + 1);
    const op = { t, by, text };
    dev.item = dev.item ? merge(dev.item, op) : op;
    return op;
  };
  const recv = (dev, op) => { dev.item = dev.item ? merge(dev.item, op) : op; };
  let now = 1_000_000;
  recv(B, edit(A, 'a', now, clockA, 'milk'));            // A (fast clock) creates the item
  now += 60_000;
  const opB = edit(B, 'b', now, clockB, 'milk x2');       // B corrects it a minute later
  recv(A, opB);
  return { A: A.item.text, B: B.item.text };
}
const before = run(false), after = run(true);
console.log('without fix:', before, before.B === 'milk x2' ? '' : '<- B\'s own edit is ignored for an hour');
console.log('with fix:   ', after, after.A === after.B && after.B === 'milk x2' ? '<- both converge on B\'s edit' : 'FAIL');
process.exitCode = after.A === 'milk x2' && after.B === 'milk x2' ? 0 : 1;
