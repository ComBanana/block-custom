const assert = require("assert");

// The streaming collision reconciliation only needs the symmetric difference
// between the old and new collision squares, even for diagonal movement.
function square(center, radius) {
  const result = new Set();
  for (let x = center.x - radius; x <= center.x + radius; x++) {
    for (let z = center.z - radius; z <= center.z + radius; z++) {
      result.add(x + "," + z);
    }
  }
  return result;
}

function incrementalCollisionChanges(oldCenter, newCenter, radius) {
  const changed = new Set();
  const minX = Math.min(oldCenter.x, newCenter.x) - radius;
  const maxX = Math.max(oldCenter.x, newCenter.x) + radius;
  const minZ = Math.min(oldCenter.z, newCenter.z) - radius;
  const maxZ = Math.max(oldCenter.z, newCenter.z) + radius;

  for (let x = minX; x <= maxX; x++) {
    for (let z = minZ; z <= maxZ; z++) {
      const wasNear = Math.abs(x - oldCenter.x) <= radius &&
        Math.abs(z - oldCenter.z) <= radius;
      const isNear = Math.abs(x - newCenter.x) <= radius &&
        Math.abs(z - newCenter.z) <= radius;
      if (wasNear !== isNear) changed.add(x + "," + z);
    }
  }
  return changed;
}

for (const radius of [0, 1, 3, 5]) {
  for (const [dx, dz] of [
    [1, 0], [-1, 0], [0, 1], [0, -1],
    [1, 1], [-1, -1], [1, -1], [-1, 1]
  ]) {
    const oldCenter = { x: -7, z: 11 };
    const newCenter = { x: oldCenter.x + dx, z: oldCenter.z + dz };
    const oldSet = square(oldCenter, radius);
    const newSet = square(newCenter, radius);
    const expected = new Set([
      ...[...oldSet].filter(key => !newSet.has(key)),
      ...[...newSet].filter(key => !oldSet.has(key))
    ]);
    const actual = incrementalCollisionChanges(oldCenter, newCenter, radius);
    assert.deepStrictEqual([...actual].sort(), [...expected].sort());
  }
}
console.log("RD32 COLLISION WINDOW REGRESSION: PASS (32 cases)");

// An in-flight read must never replace a newer deferred unload save.
function selectLoadResult(diskSnapshot, pendingSave) {
  return pendingSave === undefined ? diskSnapshot : pendingSave;
}
assert.deepStrictEqual(selectLoadResult([1, 2], [3, 4]), [3, 4]);
assert.deepStrictEqual(selectLoadResult([1, 2], undefined), [1, 2]);
console.log("PENDING SAVE PRIORITY REGRESSION: PASS");
