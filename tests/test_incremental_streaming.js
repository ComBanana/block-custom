const assert = require("assert");

function squareMembership(center, radius, x, z) {
  return x >= center.x - radius && x <= center.x + radius &&
    z >= center.z - radius && z <= center.z + radius;
}

function squareSet(center, radius) {
  const set = new Set();
  for (let x = center.x - radius; x <= center.x + radius; x++) {
    for (let z = center.z - radius; z <= center.z + radius; z++) {
      set.add(x + "," + z);
    }
  }
  return set;
}

function incrementalChanges(oldCenter, newCenter, radius) {
  const added = new Set();
  const removed = new Set();
  const addColumn = (x) => {
    for (let z = newCenter.z - radius; z <= newCenter.z + radius; z++) {
      const key = x + "," + z;
      if (!squareMembership(oldCenter, radius, x, z)) added.add(key);
    }
  };
  const removeColumn = (x) => {
    for (let z = oldCenter.z - radius; z <= oldCenter.z + radius; z++) {
      const key = x + "," + z;
      if (!squareMembership(newCenter, radius, x, z)) removed.add(key);
    }
  };
  const addRow = (z) => {
    for (let x = newCenter.x - radius; x <= newCenter.x + radius; x++) {
      const key = x + "," + z;
      if (!squareMembership(oldCenter, radius, x, z)) added.add(key);
    }
  };
  const removeRow = (z) => {
    for (let x = oldCenter.x - radius; x <= oldCenter.x + radius; x++) {
      const key = x + "," + z;
      if (!squareMembership(newCenter, radius, x, z)) removed.add(key);
    }
  };

  if (newCenter.x > oldCenter.x) {
    addColumn(newCenter.x + radius);
    removeColumn(oldCenter.x - radius);
  } else if (newCenter.x < oldCenter.x) {
    addColumn(newCenter.x - radius);
    removeColumn(oldCenter.x + radius);
  }

  if (newCenter.z > oldCenter.z) {
    addRow(newCenter.z + radius);
    removeRow(oldCenter.z - radius);
  } else if (newCenter.z < oldCenter.z) {
    addRow(newCenter.z - radius);
    removeRow(oldCenter.z + radius);
  }

  return { added, removed };
}

function verify(oldCenter, newCenter, radius) {
  const oldSet = squareSet(oldCenter, radius);
  const newSet = squareSet(newCenter, radius);
  const actualAdded = new Set([...newSet].filter((x) => !oldSet.has(x)));
  const actualRemoved = new Set([...oldSet].filter((x) => !newSet.has(x)));
  const result = incrementalChanges(oldCenter, newCenter, radius);

  assert.deepStrictEqual([...result.added].sort(), [...actualAdded].sort());
  assert.deepStrictEqual([...result.removed].sort(), [...actualRemoved].sort());
  console.log(oldCenter.x + "," + oldCenter.z + " -> " + newCenter.x + "," + newCenter.z +
    ": " + result.added.size + " added, " + result.removed.size + " removed");
}

const radius = 32;
verify({x: 0, z: 0}, {x: 1, z: 0}, radius);
verify({x: 0, z: 0}, {x: 0, z: 1}, radius);
verify({x: 0, z: 0}, {x: 1, z: 1}, radius);
verify({x: 0, z: 0}, {x: -1, z: -1}, radius);
verify({x: 15, z: -7}, {x: 16, z: -6}, radius);
console.log("INCREMENTAL STREAMING REGRESSION: PASS");
