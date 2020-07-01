# Type Imports and Exports

## Introduction

### Motivation

With [reference types](https://github.com/WebAssembly/reference-types), the type `externref` can be used to pass *extern references* from the host to Wasm code and back.
However, there are two shortcomings of `externref`:

1. An external reference is essentially untyped.
   Consequently, a host API needs to perform a runtime type check for every reference that is passed to it.

2. A value of type `externref` cannot be provided by a Wasm module itself.
   That makes its use undesirable at import boundaries,
   where it should be possible to implement any import by either the host or another Wasm module alike.

This proposal therefore allows Wasm modules to *import* type definitions.
That way, the host can provide custom types and by importing them, client Wasm code can form [typed references](https://github.com/WebAssembly/function-references) `(ref $t)` to them.
Based on that, a host API can provide functions that expect such typed references and Wasm's type soundness ensures that their type is always satisfied and no runtime check is required on the host side.

Alternatively, the same imports can be provided by another Wasm module.
In order to maintain encapsulation of such imports, even when defined in Wasm itself, the proposal further introduces the notion of *private* type definitions, which are opaque when exported.


### Design Rationale

As far as a Wasm module is concerned, _imported_ types are abstract.
Due to Wasm's staged compilation/instantiation model, an imported type's definition is not known at compile time.

However, an import may specify a subtype constraint by giving a supertype *bound* with the import (partial abstraction).
Such an import can only be instantiated by a type that actually is a subtype of the bound.
The type `any` can be used if no constraint is desired;
such an import can be instantiated with both an `extern` type provided by the host or a type implemented in Wasm itself.

Type _exports_ are transparent by default.
When using a type export to instantiate the import of another module,
its full definition is therefore available to verify any import constraints.

However, it also ought to be possible to make type exports opaque,
in order to *encapsulate* their definition (akin to an abstract data type).
There are several requirements for opaque type definitions (called "private" in this proposal):

* Encapsulation must be both static and dynamic. In particular, a cast (like the runtime type check for call_indirect, or a down cast as in the GC proposal) must not pierce through the encapsulation barrier.

* Encapsulation must also be sustained when values are passed to a high-level embedding language, such as JavaScript.

* Encapsulated values must be compatible with unconstrained imports, i.e, type `any`, such that a private type can be used to implement a type import.

* Yet, encapsulation must not get in the way of runtime type checks. For example, it must remain possible to `call_indirect` a function with a private type among its parameters (this essentially is a higher-order cast).

* In a similar vein, encapsulation must be forward-compatible with the addition of explicit casts. It ought to be possible to inject an encapsulated value into `anyref` and cast it back, in order for private types to participate in the same anyref-based type escape hatches as other references, and to avoid more complicated type system machinery. That is, it must be possible to compare with or cast _to_ a private type, but not _through_ it.

Together, these requirements and goals necessitate that (1) private types are nominal, in order to distinguish them from one another, (2) values of private type share a representation with other reference types, in order to make private types suitable for imports, and (3) these values have a distinguished representation that maintains enough type information to distinguish them from values of other type.
The latter in turn necessitates that such values are allocated -- as is typically the case for external, host-implemented references as well
(once Wasm has other forms of allocation, such as for structs in the [GC proposal](https://github.com/WebAssembly/gc), they can be used for this purpose, avoiding extra levels of exposing, see [below](#forward-compatibility-with-gc-proposal)).

The design does not enable the formation of cycles, so that simple reference counting techniques are applicable and no GC is required (though possible).


### Proposal Summary

* This proposal is based on the [reference types proposal](https://github.com/WebAssembly/reference-types) and the [typed function references proposal](https://github.com/WebAssembly/function-references).

* A new form of *type import*, `(import "..." "..." (type $t))` allows importing a type definition abstractly.

* An import may specify a subtype constraint to restrict possible instantiations, as in `(import "..." "..." (type $t (sub func)))`.

* Inversely, a new form of *type export*, `(export "..." (type <heaptype>))` allows exporting a type definition.

* A new form of *private type* definition, `(type $t (private <valtype>*))` allows the definition of types whose definition is hidden outside the exporting module.

* Private types can only be constructed and deconstructed with the pair of instructions `private.new $t`, `private.get $t`, which only validate within the module defining private type `$t`.

* Values of private type are immutable, so it is not possible to construct cycles.


### Example

Imagine an API for file operations. It could provide a type of file descriptors and operations on them that could be imported as follows:
```wasm
(import "file" "File" (type $File any))
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

It is perfectly fine to store functions like `$open` or `$close` in a table and invoke `call_indirect` on it:
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


## Language

Based on the following prerequisite proposals:

* [reference types](https://github.com/WebAssembly/reference-types), which introduces general _reference types_.

* [typed function references](https://github.com/WebAssembly/function-references), which introduces concrete reference types `(ref $t)` and the notion of _heap types_.


### Types

#### Heap Types

[Heap types](https://github.com/WebAssembly/function-references/blob/master/proposals/function-references/Overview.md#types) classify the target of a reference and are extended as follows:

* `any` is a new heap type
  - `heaptype ::= ... | any`
  - the type of all importable (and referenceable) types


#### Imports

* `type <typetype>` is an import description with a type constraint
  - `importdesc ::= ... | type <typetype>`
  - Note: `type` may get additional parameters in the future

* `sub <heaptype>` describes the type of a type import, with an upper bound
  - `typetype ::= sub <heaptype>`
  - `(sub <heaptype>) ok` iff `<heaptype> ok`
  - Note: there may be other kinds of type descriptions in the future

* Type imports share the usual type index space, and are inserted in order of appearance.

* There are additional side conditions on the ordering of type imports and definitions: they can be interleaved, but they are ordered; a type import may only be referenced by later declarations; this ensures that import bounds cannot form a non-productive definitional cycle; consecutive type definitions OTOH may be mutually recursive (the exact details of these rules are TBD and may be relaxed in future versions of Wasm; cf. Module Linking proposal).


#### Definitions

* `deftype` is a new category of *defined types* that generalises the contents of the type section
  - `deftype ::= <functype> | <privatetype>`
  - `module ::= {..., types vec(<deftype>)}`

* `private <valtype>*` is a new form of type definition
  - `privatetype ::= private <valtype>*`
  - `private <valtype>* ok` iff `(<valtype> ok)*`
  - private types are *nominal*, i.e., two structurally equivalent definitions produce distinct types
  - This is similar to a nominal immutable struct, and could later be unified with the struct mechanism under the GC proposal (see below).


#### Exports

* `type <heaptype>` is an export description
  - `exportdesc ::= ... | type <heaptype>`
  - `(type <heaptype>) ok` iff `<heaptype> ok`
  - the definition of an export type is transparently visible outside the module, except if it is defined as a private type

Question: This does not allow exposing the definition of a private type to cooperating "friend" modules.
As a more flexible alternative, hiding the definition could be optional via an explicit annotation on type exports.


#### Subtyping

The following rule extends the rules for [typed references](https://github.com/WebAssembly/function-references/proposals/function-references/Overview.md#subtyping):

* Imported types are subtypes of their bounds
  - `(type $t) <: <heaptype>`
    - iff `$t = import (sub <heaptype>)`

* Every heap type is a subtype of `any`
  - `<heaptype> <: any`
  - Note: this rule could be restricted to an ad-hoc subset of heap types, but at least needs to include `extern` and private types.

Note: There are no subtyping rules for private types other than the generic `any` supertype.
Nominal subtyping would be a possible extension, but is left out for now for the sake of simplicity.


#### Instantiation

* A type import can be instantiated only with a type that is a subtype of the specified import bound.


#### Private Types and Casts

The Wasm semantics potentially performs runtime type checks in at least two places:

* `call_indirect`, to compare function signatures
* `ref.test`/`ref.cast`, to compare source and target type (GC proposal)

In both these cases, a private type is differentiated from its representation. That is, when defining `(type $t (private i32))`, the reference type `(ref $t)` is unrelated to `(ref i32)` (if that existed).
Likewise, two private types are always distinct from each other, such that invoking `rtt.canon` with to distinct private types creates distinct runtime types.

At the same time, `$t` is still a subtype of `any`, and can e.g. be used in place of an unconstrained type import, like with the file module example above.
Moreover, this implies that `(ref $t)` is a subtype of `(ref any)`, so that the latter could be downcast to the former under the GC proposal.


### Instructions

There are only two new instructions, for creating and accessing values of private type, respectively:

* `private.new <typeidx>` creates a value of private type
  - `private.new $t : [t*] -> [(ref $t)]`
    - iff `$t = private t*`

* `private.get <typeidx> <fieldidx>` reads a field from a private value
  - `private.get $t i : [(ref null $t)] -> [t]`
    - iff `$t = private t1^i t t2*`
  - traps on `null`


## Binary Format

TODO.


## Forward Compatibility with GC Proposal

The notion of private type definition is similar to an immutable struct, as per the GC proposal.
It would be possible to later define structs in the [GC proposal](https://github.com/WebAssembly/gc) as a generalisation of private types as follows:

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

* Values of private type materialise as frozen objects with no (public) own properties.

* Question: do we need to add a `WebAssembly.Type` class to the JS API?
  - constructor `new WebAssembly.Type(name)` creates unique abstract type
