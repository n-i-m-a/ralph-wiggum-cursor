---
task: Build "racecop" - Async Race Condition Detector for TypeScript
test_command: "npm test"
completion_criteria:
  - Core analysis layer identifies shared state
  - Await points and async boundaries detected
  - Check-then-act patterns found
  - Concurrent write detection working
  - Stale closure capture detection
  - Race windows with confidence levels
  - CLI adapter working end-to-end
  - All test assertions pass
max_iterations: 100
---

# Task: Build "racecop" - Async Race Condition Detector

A static analyzer that finds race conditions in async TypeScript code before they find you.

## The One-Line Success Criterion

For any async function, racecop must answer:
1. What shared state is accessed across await boundaries?
2. Where can concurrent executions interleave dangerously?
3. What's the minimal code path that proves the race?
4. How confident are we this is a real bug?
5. What's the suggested fix?

If you ship that, senior engineers will finally stop saying "it works on my machine."

---

## The Problem

Race conditions in async JavaScript/TypeScript are:
- **Silent**: No compiler errors, no runtime exceptions (usually)
- **Intermittent**: Work 99% of the time, fail in production
- **Invisible**: No tooling catches them statically
- **Everywhere**: Every `await` is a potential race window

### Classic Examples That Ship to Production

```typescript
// 1. Check-then-act (TOCTOU)
let cache = null;
async function getUser() {
  if (!cache) {                    // CHECK
    cache = await fetchUser();     // ACT - another call can enter between!
  }
  return cache;
}

// 2. Stale closure
function SearchBox() {
  const [query, setQuery] = useState('');
  
  useEffect(() => {
    fetchResults(query).then(results => {
      setResults(results);  // BUG: query may have changed!
    });
  }, [query]);
}

// 3. Concurrent writes
let requestId = 0;
async function search(term) {
  requestId++;                     // WRITE
  const myId = requestId;
  const results = await fetch(term);
  if (myId === requestId) {        // READ - but requestId changed!
    return results;
  }
}
```

---

## Architecture (Do Not Deviate)

```
┌─────────────────────────────────────────────────────────────┐
│                        ADAPTERS                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │     CLI     │  │     LSP     │  │    JSON Export      │  │
│  │  (build)    │  │  (future)   │  │    (build)          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         ENGINE                               │
│  - Async CFG (Control Flow Graph with await edges)          │
│  - Shared state tracker                                      │
│  - Interleaving analyzer                                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                          CORE                                │
│  - Input: TS Program + Config                               │
│  - Output: RaceViolations + SharedStateMap + Traces         │
│  - PURE: No CLI, no side effects                            │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Data Types

### Confidence Levels (Soundness) - MANDATORY

```typescript
type Confidence = "certain" | "likely" | "possible" | "unlikely";

type RacePattern =
  | "check-then-act"       // if (!x) { x = await ... }
  | "concurrent-write"     // multiple async paths write same var
  | "stale-closure"        // closure captures var, await happens, var changes
  | "unguarded-init"       // lazy init without lock
  | "read-after-write"     // read depends on write across await
  | "toctou";              // time-of-check-time-of-use

interface RaceViolation {
  pattern: RacePattern;
  confidence: Confidence;           // REQUIRED
  sharedState: SharedStateRef;      // What variable/property is at risk
  checkLocation?: SourceLocation;   // Where the "check" happens (if applicable)
  actLocation: SourceLocation;      // Where the dangerous "act" happens
  awaitBetween: SourceLocation[];   // Await points in the race window
  trace: RaceTrace;                 // How to reproduce
  suggestion?: string;              // Fix suggestion
}
```

### Shared State Detection

```typescript
type StateScope = "module" | "closure" | "object-property" | "parameter";

interface SharedStateRef {
  name: string;
  scope: StateScope;
  declaredAt: SourceLocation;
  isMutable: boolean;              // let vs const, but also property writes
  accessedInAsync: boolean;        // Used in async function/callback
}

interface StateAccess {
  state: SharedStateRef;
  kind: "read" | "write";
  location: SourceLocation;
  inAsyncContext: boolean;
  awaitsBefore: SourceLocation[];  // Awaits that happened before this access
}
```

### Race Traces

```typescript
interface RaceTrace {
  scenario: string;                 // Human-readable "what goes wrong"
  timeline: TraceEvent[];           // Interleaved execution showing the race
}

interface TraceEvent {
  execution: "A" | "B";             // Which concurrent execution
  action: string;                   // What happens
  location: SourceLocation;
  stateSnapshot?: Record<string, string>;  // State after this event
}
```

### Analysis Result

```typescript
interface AnalyzeResult {
  violations: RaceViolation[];
  sharedState: SharedStateRef[];    // All shared state found
  asyncFunctions: AsyncFunctionInfo[];
  files: string[];
  summary: {
    total: number;
    byConfidence: Record<Confidence, number>;
    byPattern: Record<RacePattern, number>;
  };
}
```

---

## Race Detection Patterns

### Pattern 1: Check-Then-Act (TOCTOU)

```typescript
// RACE: Another call can enter between check and assignment
let cache = null;
async function getData() {
  if (!cache) {           // CHECK
    cache = await fetch(); // ACT
  }
  return cache;
}
```

**Detection:**
1. Find `if (!var)` or `if (var === null)` checks
2. Check if the body contains `await`
3. Check if `var` is assigned after the await
4. If all true → check-then-act race

### Pattern 2: Concurrent Write

```typescript
// RACE: Concurrent calls increment, overwriting each other
let counter = 0;
async function increment() {
  const current = counter;    // READ
  await delay(100);
  counter = current + 1;      // WRITE - stale!
}
```

**Detection:**
1. Find read of shared state
2. Find write of same state after await
3. If write depends on the read → concurrent write race

### Pattern 3: Stale Closure

```typescript
// RACE: Closure captures query, but query changes during await
function search(query) {
  fetchResults(query).then(results => {
    if (query === currentQuery) {  // query is STALE
      setResults(results);
    }
  });
}
```

**Detection:**
1. Find closure/callback passed to async operation
2. Find variables from outer scope used in closure
3. Check if outer variable can change while async is pending
4. If yes → stale closure race

### Pattern 4: Unguarded Lazy Initialization

```typescript
// RACE: Multiple calls can all see promise as null
let promise = null;
async function getSingleton() {
  if (!promise) {
    promise = createAsync();  // Should assign BEFORE await
  }
  return await promise;       // Multiple instances created!
}
```

**Detection:**
1. Find lazy init pattern with async
2. Check if promise/lock is set AFTER await vs BEFORE
3. If after → unguarded init race

### Pattern 5: Read-After-Write Dependency

```typescript
// RACE: requestId changes while we're awaiting
let requestId = 0;
async function search(term) {
  requestId++;
  const myId = requestId;
  const results = await fetch(term);
  if (myId === requestId) {  // requestId may have changed!
    return results;
  }
}
```

**Detection:**
1. Find write to shared state
2. Find read of same state after await
3. Check if logic depends on them being equal → dependency race

---

## Success Criteria

### Phase 1: Core Foundation (Pure Layer)
1. [ ] Parse TypeScript files using Compiler API
2. [ ] Identify async functions and methods
3. [ ] Find all `await` expressions and their locations
4. [ ] Identify shared state (module-level, closure-captured, object properties)
5. [ ] Track read/write access to shared state
6. [ ] Core is pure: no I/O, no CLI, just data in → data out

### Phase 2: Check-Then-Act Detection
7. [ ] Detect `if (!var)` and `if (var == null)` patterns
8. [ ] Check if await exists between check and modification
9. [ ] Generate check-then-act violations with correct locations
10. [ ] Confidence: "certain" if direct pattern, "likely" if variant
11. [ ] Generate human-readable trace showing the race

### Phase 3: Concurrent Write Detection
12. [ ] Detect read of shared state
13. [ ] Detect write to same state after await
14. [ ] Flag when write depends on earlier read (stale read)
15. [ ] Track multiple async entry points that write same state
16. [ ] Generate concurrent-write violations

### Phase 4: Stale Closure Detection
17. [ ] Detect closures passed to Promise.then, setTimeout, event handlers
18. [ ] Identify variables captured from outer scope
19. [ ] Check if captured variables can change during async gap
20. [ ] Generate stale-closure violations
21. [ ] Special handling for React useEffect patterns

### Phase 5: Advanced Patterns
22. [ ] Detect unguarded lazy initialization
23. [ ] Detect read-after-write dependency races
24. [ ] Handle Promise.all with dependent operations
25. [ ] Detect potential double-fetch patterns
26. [ ] Track state across multiple awaits in sequence

### Phase 6: CLI Adapter
27. [ ] `racecop analyze <path>` - analyze files/directory
28. [ ] `racecop analyze --function <name>` - analyze specific function
29. [ ] `--output json` - machine-readable output
30. [ ] `--output pretty` - human-readable with colors and traces
31. [ ] `--confidence <level>` - filter by minimum confidence
32. [ ] Exit code 1 if certain/likely races found, 0 otherwise

### Phase 7: Polish & Edge Cases
33. [ ] Handle try/catch around await (doesn't prevent race)
34. [ ] Detect races in class methods with `this` state
35. [ ] Handle async generators
36. [ ] Configurable: ignore test files, specific patterns
37. [ ] Suggest fixes in output

---

## MANDATORY TEST CASES

### Test 1: Basic Check-Then-Act
```typescript
// test/fixtures/check-then-act.ts
let cache: string | null = null;

export async function getCached(): Promise<string> {
  if (!cache) {
    cache = await fetchData();
  }
  return cache;
}

async function fetchData(): Promise<string> {
  return "data";
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/check-then-act.ts --output json').toString();
assert(output.length > 10, "CLI must produce output");

const result = JSON.parse(output);
assert(result.violations.length > 0, "Must find violations");

const race = result.violations[0];
assert(race.pattern === "check-then-act", "Pattern must be check-then-act");
assert(race.confidence === "certain" || race.confidence === "likely", "Must have high confidence");
assert(race.sharedState.name === "cache", "Shared state must be cache");
assert(race.awaitBetween.length > 0, "Must show await in race window");
```

---

### Test 2: Concurrent Write (Stale Read)
```typescript
// test/fixtures/concurrent-write.ts
let counter = 0;

export async function increment(): Promise<number> {
  const current = counter;
  await delay(100);
  counter = current + 1;
  return counter;
}

function delay(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms));
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/concurrent-write.ts --output json').toString();
const result = JSON.parse(output);

const race = result.violations.find(v => v.pattern === "concurrent-write");
assert(race, "Must find concurrent-write violation");
assert(race.sharedState.name === "counter", "Shared state must be counter");

// Must show the read and write locations
assert(race.trace.timeline.length >= 2, "Trace must show interleaving");
```

---

### Test 3: Stale Closure
```typescript
// test/fixtures/stale-closure.ts
let currentQuery = "";

export function search(query: string): void {
  currentQuery = query;
  
  fetchResults(query).then(results => {
    // BUG: currentQuery may have changed!
    if (query === currentQuery) {
      console.log("Results:", results);
    }
  });
}

async function fetchResults(q: string): Promise<string[]> {
  return [q];
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/stale-closure.ts --output json').toString();
const result = JSON.parse(output);

const race = result.violations.find(v => v.pattern === "stale-closure");
assert(race, "Must find stale-closure violation");
assert(race.sharedState.name === "currentQuery", "Must identify currentQuery as stale");
```

---

### Test 4: Unguarded Lazy Init
```typescript
// test/fixtures/unguarded-init.ts
let singletonPromise: Promise<Service> | null = null;

export async function getSingleton(): Promise<Service> {
  if (!singletonPromise) {
    // BUG: Should assign before await, not after
    const service = await createService();
    singletonPromise = Promise.resolve(service);
  }
  return singletonPromise;
}

interface Service { id: number }
async function createService(): Promise<Service> {
  return { id: Math.random() };
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/unguarded-init.ts --output json').toString();
const result = JSON.parse(output);

const race = result.violations.find(v => v.pattern === "unguarded-init" || v.pattern === "check-then-act");
assert(race, "Must find unguarded init violation");
```

---

### Test 5: Safe Pattern (No Violation)
```typescript
// test/fixtures/safe-init.ts
let singletonPromise: Promise<Service> | null = null;

export async function getSafeSingleton(): Promise<Service> {
  if (!singletonPromise) {
    // SAFE: Assign promise BEFORE await
    singletonPromise = createService();
  }
  return singletonPromise;
}

interface Service { id: number }
async function createService(): Promise<Service> {
  return { id: 1 };
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/safe-init.ts --output json').toString();
const result = JSON.parse(output);

// This pattern is SAFE - no check-then-act because promise is assigned before await
const violations = result.violations.filter(v => 
  v.pattern === "check-then-act" && 
  v.sharedState.name === "singletonPromise"
);
assert(violations.length === 0, "Safe singleton pattern should not be flagged");
```

---

### Test 6: Request ID Pattern
```typescript
// test/fixtures/request-id.ts
let requestId = 0;

export async function search(term: string): Promise<string[] | null> {
  requestId++;
  const myId = requestId;
  const results = await fetchResults(term);
  
  // BUG: requestId may have changed during await
  if (myId === requestId) {
    return results;
  }
  return null;
}

async function fetchResults(term: string): Promise<string[]> {
  return [term];
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/request-id.ts --output json').toString();
const result = JSON.parse(output);

const race = result.violations.find(v => v.pattern === "read-after-write");
assert(race, "Must find read-after-write violation");
assert(race.sharedState.name === "requestId", "Must identify requestId");
```

---

### Test 7: Class Instance State
```typescript
// test/fixtures/class-state.ts
export class DataFetcher {
  private cache: Map<string, string> | null = null;
  
  async getData(key: string): Promise<string | undefined> {
    if (!this.cache) {
      this.cache = await this.loadCache();
    }
    return this.cache.get(key);
  }
  
  private async loadCache(): Promise<Map<string, string>> {
    return new Map([["key", "value"]]);
  }
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/class-state.ts --output json').toString();
const result = JSON.parse(output);

const race = result.violations.find(v => v.sharedState.name.includes("cache"));
assert(race, "Must find race on this.cache");
assert(race.sharedState.scope === "object-property", "Must identify as object property");
```

---

### Test 8: React useEffect Pattern
```typescript
// test/fixtures/react-effect.ts
// Simulating React hooks pattern
type SetState<T> = (value: T) => void;

export function useSearch(query: string, setResults: SetState<string[]>) {
  // This is the classic stale closure bug in React
  fetchResults(query).then(results => {
    setResults(results);  // query may be stale!
  });
}

async function fetchResults(q: string): Promise<string[]> {
  return [q];
}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/react-effect.ts --output json').toString();
const result = JSON.parse(output);

// Should detect potential stale closure with query
const staleWarning = result.violations.find(v => 
  v.pattern === "stale-closure" && v.confidence !== "unlikely"
);
// This is a softer check - may be "possible" confidence since we don't know if query changes
assert(result.violations.length >= 0, "Should analyze without crashing");
```

---

### Test 9: Multiple Awaits in Sequence
```typescript
// test/fixtures/multi-await.ts
let state = { step: 0 };

export async function multiStep(): Promise<void> {
  state.step = 1;
  await step1();
  
  state.step = 2;  // Race: state.step could have been modified by another call
  await step2();
  
  state.step = 3;
  await step3();
}

async function step1(): Promise<void> {}
async function step2(): Promise<void> {}
async function step3(): Promise<void> {}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/multi-await.ts --output json').toString();
const result = JSON.parse(output);

// Should find multiple race windows
assert(result.violations.length >= 1, "Must find violations in multi-await sequence");

// Should track state.step as shared
const stateRefs = result.sharedState.filter(s => s.name.includes("step") || s.name.includes("state"));
assert(stateRefs.length > 0, "Must identify state.step as shared");
```

---

### Test 10: Summary Statistics
```typescript
// test/fixtures/mixed.ts
let a = 0;
let b = 0;

export async function raceA(): Promise<void> {
  if (!a) { a = await getA(); }  // check-then-act
}

export async function raceB(): Promise<void> {
  const old = b;
  await delay();
  b = old + 1;  // concurrent-write
}

async function getA(): Promise<number> { return 1; }
async function delay(): Promise<void> {}
```

**Test assertions:**
```javascript
const output = execSync('node dist/index.js analyze test/fixtures/mixed.ts --output json').toString();
const result = JSON.parse(output);

assert(result.summary, "Must have summary");
assert(result.summary.total >= 2, "Must find at least 2 violations");
assert(result.summary.byPattern["check-then-act"] >= 1, "Must count check-then-act");
assert(result.summary.byPattern["concurrent-write"] >= 1, "Must count concurrent-write");
```

---

## File Structure

```
racecop/
├── src/
│   ├── core/
│   │   ├── index.ts           # Core exports
│   │   ├── types.ts           # All type definitions
│   │   ├── parser.ts          # TS parsing utilities
│   │   ├── async-finder.ts    # Find async functions and awaits
│   │   ├── state-tracker.ts   # Track shared state access
│   │   ├── race-detector.ts   # Main detection logic
│   │   ├── patterns/
│   │   │   ├── check-then-act.ts
│   │   │   ├── concurrent-write.ts
│   │   │   ├── stale-closure.ts
│   │   │   └── unguarded-init.ts
│   │   └── trace-builder.ts   # Build human-readable traces
│   ├── engine/
│   │   ├── index.ts           # Engine exports
│   │   └── analyzer.ts        # Orchestrates analysis
│   ├── adapters/
│   │   ├── cli.ts             # CLI implementation
│   │   ├── json.ts            # JSON output formatter
│   │   └── pretty.ts          # Pretty terminal output
│   └── index.ts               # Main entry
├── test/
│   ├── fixtures/              # Test TypeScript files
│   │   ├── check-then-act.ts
│   │   ├── concurrent-write.ts
│   │   ├── stale-closure.ts
│   │   ├── unguarded-init.ts
│   │   ├── safe-init.ts
│   │   ├── request-id.ts
│   │   ├── class-state.ts
│   │   ├── react-effect.ts
│   │   ├── multi-await.ts
│   │   └── mixed.ts
│   └── run-tests.js           # Test runner
├── package.json
├── tsconfig.json
└── README.md
```

---

## Example Output

### Pretty Output
```
$ racecop analyze src/ --output pretty

🔍 racecop - Async Race Condition Detector
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔴 CERTAIN: Check-Then-Act Race
   Location: src/cache.ts:15
   Shared State: cache (module scope)
   
   The check `if (!cache)` and assignment `cache = await ...`
   have an await between them. Concurrent calls can both
   see cache as null and fetch duplicate data.
   
   Timeline:
   ┌─────────┬────────────────────────────────────┐
   │ Call A  │ if (!cache) → true                 │
   │ Call B  │ if (!cache) → true (A hasn't set!) │
   │ Call A  │ cache = await fetch() → "data1"    │
   │ Call B  │ cache = await fetch() → "data2"    │ ← overwrites!
   └─────────┴────────────────────────────────────┘
   
   💡 Fix: Assign promise before await:
      if (!cache) {
        cache = fetchData();  // assign promise, not result
      }
      return await cache;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Summary: 3 races found
  🔴 Certain: 1
  🟠 Likely:  1  
  🟡 Possible: 1
```

---

## Dependencies

- `typescript` (Compiler API) - ONLY external dependency for core
- `commander` (CLI parsing) - for CLI adapter only
- `chalk` (optional) - for pretty output colors
- Node.js built-ins

---

## Constraints

- **Core must be pure** - No I/O, no side effects, just analysis
- **Tests MUST test the CLI** - Use execSync to run the actual CLI
- **Tests must assert on pattern types** - Not just "found something"
- **Confidence must be explicit** - Never claim certainty without proof
- **Traces must be reproducible** - Show exact interleaving that causes race
- **Task is NOT complete until `npm test` exits with code 0**

---

## Traps to Avoid

1. **Don't flag everything as a race** - Be precise about what constitutes shared state
2. **Don't ignore Promise.then** - It's async too, even without await keyword
3. **Don't forget class instance state** - `this.foo` across methods can race
4. **Don't assume single-threaded means safe** - Async interleaving breaks assumptions
5. **Don't skip the trace** - Developers need to SEE the interleaving to believe it
6. **Don't forget safe patterns** - Assigning promise before await IS safe

---

## Ralph Instructions

1. Build Phase 1 first - get state tracking working before detection
2. **Run `npm test` after EVERY change**
3. Confidence levels are NOT optional - implement from the start
4. Check-then-act is the most important pattern - nail it first
5. If tests fail, read the failure and fix
6. **Tests use execSync to run CLI** - If CLI produces no output, tests will fail
7. Commit after each phase
8. When ALL criteria are [x] AND `npm test` passes: `RALPH_COMPLETE`
9. If stuck on same issue 3+ times: `RALPH_GUTTER`
