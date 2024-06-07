# Type Imports and Exports

## Introduction

### Motivation

With [reference types](https://github.com/WebAssembly/reference-types), the type `externref` (or `ref extern`) can be used to pass *extern references* from the host to Wasm code and back.
Similarly, with [GC types](https://github.com/WebAssembly/gc), the type `anyref` (or `ref any`) can be used to pass generic references from other Wasm modules without locking down their representation.

However, using these "top" types for abstracting over outside types has the significant drawback that it essentially makes them _untyped_.
Precise type information is lost when going to these types.
Consequently, a host API, or another Wasm module, needs to perform a runtime type check for every reference that is passed (back) to it.

This proposal therefore allows Wasm modules to *import* actual type definitions.
That way, the host, or another Wasm module, can provide custom types and by importing them, client Wasm code can form [typed references](https://github.com/WebAssembly/function-references) `(ref $t)` to them.
Based on that, an API can provide functions that expect such typed references and Wasm's type soundness ensures that their type is always satisfied and no runtime check is required on the host side.

Alternatively, the same imports can be provided by another Wasm module.
In order to maintain encapsulation of such imports, even when defined in Wasm itself, the proposal further introduces the notion of *private* type definitions, which are opaque when exported. (This may be a post-MVP feature.)


### Design Rationale

This proposal is intended as an MVP ("minimal viable product") version of type imports.
As such, it tries to remain minimally invasive to Wasm's semantics and its compilation model.
That implies the following:

* No new class of type definitions is introduced; all type indices continue to refer to (definitions for) heap types, including those denoting imports and exports.

* The representation of all types is still known at compile time. In particular, it does not depend on how a type import is instantiated. Imports specify a heap type bound (a supertype such as `extern`, `any`, `func`, or some subtype thereof) that statically determines their (uniform) representation.

* To avoid the possiblity for mutual dependencies between type imports and type definition sections, and thereby the need for relaxing the section order in the binary format, import bounds are restricted to _abstract_ heap types in the MVP.

* Type imports are purely a validation-time feature, they do not affect the runtime semantics, relative to using top types.
  (TODO: What about casts?)

As far as a Wasm module is concerned, _imported_ types are abstract.
Due to Wasm's staged compilation/instantiation model, an imported type's definition is not known at compile time, even though its representation is.

Type _exports_ are transparent by default.
When using a type export to instantiate the import of another module,
its full definition is therefore available to verify any import constraints.

However, it also ought to be possible to make type exports opaque,
in order to *encapsulate* their definition (akin to an abstract data type).
**At this point we consider this a post-MVP feature.**

There are several requirements for opaque type definitions (called "private" in this proposal):

* Encapsulation must be both static and dynamic. In particular, a cast (like the runtime type check for call_indirect, or a down cast as in the GC proposal) must not pierce through the encapsulation barrier.

* Encapsulation must also be sustained when values are passed to a high-level embedding language, such as JavaScript.

* Encapsulated values must be compatible with unconstrained imports, i.e, type `any`, such that a private type can be used to implement a type import.

* Yet, encapsulation must not get in the way of runtime type checks. For example, it must remain possible to `call_indirect` a function with a private type among its parameters (this essentially is a higher-order cast).

* In a similar vein, encapsulation must be forward-compatible with the addition of explicit casts. It ought to be possible to inject an encapsulated value into `any` and cast it back, in order for private types to participate in the same anyref-based type escape hatches as other references, and to avoid more complicated type system machinery. That is, it must be possible to compare with or cast _to_ a private type, but not _through_ it.

Together, these requirements and goals necessitate that (1) private types are nominal, in order to distinguish them from one another, (2) values of private type share a representation with other reference types, in order to make private types suitable for imports, and (3) these values have a distinguished representation that maintains enough information to distinguish them from values of other type.
The latter in turn necessitates that such values are allocated -- as is typically the case for external, host-implemented references as well
(once Wasm has other forms of allocation, such as for structs in the [GC proposal](https://github.com/WebAssembly/gc), they can be used for this purpose, avoiding extra levels of indirection, see [below](#forward-compatibility-with-gc-proposal)).

The design for private types does not itself enable the formation of heap cycles, so that simple reference counting techniques are possbile and they can still be implemented in no-GC environments.


### Proposal Summary

* This proposal is based on the [reference types proposal](https://github.com/WebAssembly/reference-types), the [typed function references proposal](https://github.com/WebAssembly/function-references), and the type structure in the [GC proposal](https://github.com/WebAssembly/gc).

* A new form of *type import*, `(import "..." "..." (type $t (sub <absheaptype>)))` allows importing a type definition abstractly.

* The subtype constraint on the import determines the representation and restricts possible instantiations.
  (The text format allows to omit the constraint, in which case it defaults to `(sub any)`.)

* Inversely, a new form of *type export*, `(export "..." (type $t))` allows exporting a type definition.

* Finally, type definitions are generalised to allow arbitrary heap types as definitions, such as `(type $t i31)`.

**Post-MVP:**

* A new form of *private type* definition, `(type $t (private <valtype>*))` allows the definition of types whose definition is hidden outside the exporting module.

* Private types can only be constructed and deconstructed with the pair of instructions `private.new $t`, `private.get $t`, which only validate within the module defining private type `$t`.

* Values of private type are immutable, so it is not possible to construct heap cycles.


### Example

Imagine an API for file operations. It could provide a type of file descriptors and operations on them that could be imported as follows:
```wasm
(import "file" "File" (type $File (sub any)))
(import "file" "open" (func $open (param $name i32) (result (ref $File))))
(import "file" "read_byte" (func $read (param (ref $File)) (result i32)))
(import "file" "close" (func $close (param (ref $File))))
```
For the following code,
```wasm
(func $read3 (param $f (ref $File)) (result i32 i32 i32)
  (call $read (local.get $f))
  (call $read (local.get $f))
  (call $read (local.get $f))
  (call $close (local.get $f))
)

(func (param $path i32)
  (call $read3 (call $open (local.get $path)))
)
```
the Wasm type system would guarantee the invariant that any reference passed to the `$read` and `$close` functions can only be one that was previously produced by a call to `$open`.

The type `$File` is abstract to any client code.
It cannot make any assumptions about its definition.
Consequently, the `"file"` module could be implemented either by the host, in which case type `"File"` would probably be instantiated with type `extern`;
or by another Wasm module, in which case it would probably consist of a private type exported by that module.
This is immaterial to the client module, which can only store references to it and pass them to the imported functions.

It still is perfectly fine to store functions like `$open` or `$close` in a table and invoke `call_indirect` on it:
```wasm
(table $t 10 funcref)
(elem (table $t) (i32.const 0) $open $close $read)
...
(call_indirect (param i32) (result (ref $File)) (i32.const 0))  ;; open
(call_indirect (param (ref $File)) (i32.const 1))               ;; close
```

A Wasm module could implement the `file` interface in the following manner, using a private type to represent the `File` type:
```wasm
(module
  ...
  (type $File (export "File") (private i32))  ;; file handle

  (func (export "open") (param $name i32) (result (ref $File)) ...)
  (func (export "close" (param (ref $File))) ...)
  (func (export "read_byte" (param (ref $File)) (result i32)) ...)
  ...
)
```

In the presence of the GC proposal (see below), a client could try to *guess* the type definition for an import, and if it is a scalar or data type (struct or array), could attempt to *cast* a value to that type to reveal its contents. Or vice versa, it could forge a value of the imported type by casting the opposite direction. The use of private types protects against such attempts to break encapsulation, in scenarios where clients are potentially untrusted.


## Language

Based on the following prerequisite proposals:

* [reference types](https://github.com/WebAssembly/reference-types), which introduces general _reference types_.

* [typed function references](https://github.com/WebAssembly/function-references), which introduces concrete reference types `(ref $t)` and the notion of _heap types_.


### Types

#### Imports

* `type <typetype>` is an import description with a type constraint
  - `importdesc ::= ... | type <typetype>`
  - Note: `type` may get additional parameters in the future

* `sub <heaptype>` describes the type of a type import, with an upper bound
  - `typetype ::= sub <heaptype>`
  - `(sub <heaptype>) ok` iff `<heaptype> ok`
  - Note: there may be other kinds of type descriptions in the future
  - Note: In the MVP the bound is syntactically restricted to _abstract_ heap types (which excludes type indices, and therefor concrete defined types)

* Type imports share the usual type index space, and are inserted in order of appearance, before all internal type definitions.


#### Definitions

**Post-MVP:**

* `private <valtype>*` is a new form of type definition
  - `privatetype ::= private <valtype>*`
  - `private <valtype>* ok` iff `(<valtype> ok)*`
  - private types are *nominal*, i.e., two structurally equivalent definitions produce distinct types
  - This is similar to a nominal immutable struct, and could later be unified with the struct mechanism under the GC proposal (see below).


#### Exports

* `type <typeidx>` is an export description
  - `exportdesc ::= ... | type <typeidx>`
  - `(type <typeidx>) ok` iff `<typeidx> ok`
  - Note: the definition of an export type is transparently observable outside the module, unless it is defined as a private type


#### Subtyping

The following rule extends the rules for [typed references](https://github.com/WebAssembly/function-references/proposals/function-references/Overview.md#subtyping):

* Imported types are subtypes of their bounds
  - `(type $t) <: <heaptype>`
    - iff `$t = import (sub <heaptype>)`

**Post-MVP:**

* Private types are subtypes of `any`
  - `(type $t) <: any`
    - iff `$t = private <valtype>*`

Note: There are no subtyping rules for private types other than the generic `any` supertype.
(Nominal) subtyping would be a possible extension, but is left out for now for the sake of simplicity.


#### Instantiation

* A type import can be instantiated only with a type that is a subtype of the specified import bound.


#### Private Types and Casts

The Wasm semantics potentially performs runtime type checks in at least two places:

* `call_indirect`, to compare function signatures
* `ref.test`/`ref.cast`, to compare source and target type (GC proposal)

In both these cases, a private type is differentiated from its representation. That is, when defining `(type $t (private i32))`, the reference type `(ref $t)` is unrelated to `(ref i32)` (if that existed).
Likewise, two private types are always distinct from each other, i.e., they have distinct runtime types.

At the same time, `$t` is still a subtype of `any`, and can e.g. be used in place of an unconstrained type import, like with the file module example above.
Moreover, this implies that `(ref $t)` is a subtype of `(ref any)`, so that the latter could be downcast to the former under the GC proposal.


### Instructions

**Post-MVP:**

There are only two new instructions, for creating and accessing values of private type, respectively:

* `private.new <typeidx>` creates a value of private type
  - `private.new $t : [t*] -> [(ref $t)]`
    - iff `$t = private t*`

* `private.get <typeidx> <fieldidx>` reads a field from a private value
  - `private.get $t i : [(ref null $t)] -> [t]`
    - iff `$t = private t1^i t t2*`
  - traps on `null`

Question: We could consider mutable fields in a private type, which would bring it even closer to a struct as in the GC proposal (see below).


## Binary Format

Note: This is preliminary, expect changes. In particular, we may want to impose strict def-use ordering constraints on type imports and type definitions, which may require splitting up type and/or import sections.

### Imports / Exports

#### External Kind

The following *external kind* is added:

* `0x05` indicating a `Type` import

#### Import section

The import section is extended to include type imports by extending an `importdesc` as follows:

If the `kind` is `Type`:

| Field | Type | Description |
|-------|------|-------------|
| `type` | `typetype` | the type being imported |


* In the binary format, an additional import section may appear _before_ the type section. This section may only containt type imports. In contrast, the import section after the type section may not contain any type imports. (They both use the same section id and format, however. This is to remain forward-compatible with a possible relaxation of section order.)

#### Export section

The export section is extended to reference type imports by extending an `exportdesc` as follows:

If the `kind` is `Type`:

| Field | Type | Description |
|-------|------|-------------|
| `type` | `typeidx (s33)` | a heap type to export (as type indices are heap types, can also be an index) |

Note: The type index is represented as an s33 in order to allow future generalisations to arbitrary heap types.

#### Type type

Each `typetype` has the fields:

| Field | Type | Description |
|-------|------|-------------|
| `boundkind` | `u8` | The kind of a type import bound |
| `bound` | `heaptype` | The heap type that is a bound for the type import |

An `boundkind` can take the following value:

| Name      | Value | Description |
|-----------|-------|----------------|
| `sub` | 0     | An import that is a subtype of the bound |

Note: Other forms of bounds may be added in the future.


## Forward Compatibility with GC Proposal

The notion of private type definition is similar to an immutable struct, as per the  [GC proposal](https://github.com/WebAssembly/gc).
It would be possible to unify structs and private types as follows:

* Private types are reinterpreted as a special case of a struct definition, albeit a nominal one.
  That is,
  ```
  (type $t (private i32 i64))
  ```
  gets desugared into
  ```
  (type $t (private struct (field i32) (field i64)))
  ```

* They are defined to be a subtype of the underlying (structural) struct type.
  That is,
  ```
  (private struct ...) <: (struct ...)
  ```
  within the scope of its definition.

* Then the `private.get` instruction becomes `struct.get`, which is still applicable to private values by way of subsumption.
  That is,
  ```
  (private.get $t i)
  ```
  gets desugared into
  ```
  (struct.get $t i)
  ```

* It would furthermore be possible to orthogonalise `private` and `struct` and thereby allow other variations of private types, such as private arrays or private functions.
  That is,
  ```
  (type $a (private array i32))
  (type $f (private func (param i32)))
  ```
  would be possible extensions.


## JS API

* Question: do we need to add a `WebAssembly.Type` class to the JS API?
  - constructor `new WebAssembly.Type(name)` would create a unique host type

**Post-MVP:**

* Like other GC type values of private type materialise as frozen objects with no (public) own properties.
