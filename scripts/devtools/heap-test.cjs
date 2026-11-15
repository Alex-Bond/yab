const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const c={console};vm.createContext(c);vm.runInContext(fs.readFileSync(__dirname+'/../../Resources/DevTools/heap-snapshot.js','utf8'),c);
function snapshot(nodes,edges){c.fixture=JSON.stringify({version:3,nodes,nodeClassNames:['<root>','Object','String'],edges,edgeTypes:['Property'],edgeNames:['a','b','c']});return vm.runInContext('new HeapSnapshot(null,0,fixture)',c)}
let chain=snapshot([0,0,0,0,1,16,1,2,2,32,1,2,3,8,2,0],[0,1,0,0,1,2,0,1,2,3,0,2]);
assert.equal(chain.serialize().totalSize,56);assert.equal(chain.nodeWithIdentifier(1).retainedSize,56);assert.equal(chain.nodeWithIdentifier(3).dominatorNodeIdentifier,2);
let diamond=snapshot([0,0,0,0,1,16,1,2,2,32,1,2,3,8,2,0],[0,1,0,0,0,2,0,1,1,3,0,2,2,3,0,2]);
assert.equal(diamond.nodeWithIdentifier(3).dominatorNodeIdentifier,0);assert.equal(diamond.nodeWithIdentifier(1).retainedSize,16);assert.equal(diamond.nodeWithIdentifier(2).retainedSize,32);
console.log('PASS heap graph: final node, chain retained sizes, shared-child dominator');
