# Type Imports and Exports

## Introduction

### Motivation

With [reference types](https://github.com/WebAssembly/reference-types), the type `anyref` can be used to pass *host references* to Wasm code and back.
However, being a top type, such references are essentially untyped.
Consequently, a host API needs to perform runtime type checks for each reference that is passed to it.

This proposal allows Wasm modules to *import* type definitions.
That way, the host can provide custom types and by importing them, Wasm code can form [typed references](https://github.com/WebAssembly/function-references) `(ref $t)` to them.
Based on that, a host API can provide functions that expect such typed references and Wasm's type soundness ensures that this type is always satisfied and no runtime check is required on the host side.

As far as the Wasm code is concerned, imported types are completely abstract.
However, an import may specify a subtype relation between these abstract types by specifying supertypes with the import.
Such an import can only be instantiated by a type that actually is a subtype.


### Summary

* This proposal is based on the [reference types proposal](https://github.com/WebAssembly/reference-types) and the [typed function references proposal](https://github.com/WebAssembly/function-references).

* Add a new form of import, `(import "..." "..." (type $t))`, that allows importing a type definition abstractly

* Add a new form of export, `(export "..." (type $t))`, that allows exporting a type definition

* Allow subtyping bounds on a type import, as in `(import "..." "..." (type $t (sub $t')))`, that restrict possible instantiations


### Examples

Imagine an API for file operations. It could provide a type of file descriptors and operations on them that could be imported as follows:
```wasm
(import "file" "File" (type $File))
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


## Language

Based on the following proposals:

* [reference types](https://github.com/WebAssembly/reference-types), which introduces type `anyref` etc.

* [typed function references](https://github.com/WebAssembly/function-references), which introduces types `(ref $t)` and `(optref $t)` etc.

Both these proposals are prerequisites.


### Types

#### Imports

* `type <typetype>` is an import description with an upper bound
  - `importdesc ::= ... | type <typetype>`
  - Note: `type` may get additional parameters in the future

* `typetype` describes the type of a type import, as an upper bound
  - `typetype ::= sub <constype>`
  - `(sub <constype>) ok` iff `<constype> <: any`
  - Note: the side condition ensures that bounds do not form a non-productive cycle (technicality: requires tweaking spec of subyping any)
  - Note: the bound can be a function type
  - Note: there may be other kinds of type descriptions in the future

* Type imports have indices prepended to the type index space, similar to other imports.
  - Note: due to bounds, type imports can be mutually recursive with other type imports as well as regular type definitions. Hence they have to be validated together with the type section.


#### Exports

* `type <constype>` is an export description
  - `exportdesc ::= ... | type <constype>`
  - `(type <constype>) ok` iff `<constype> ok`

Note: `<constype>` is defined in the [typed function references proposal](https://github.com/WebAssembly/function-references). It is either a type index or a predefined type like `any`, `func`, etc.


#### Subtyping

Greatest fixpoint (co-inductive interpretation) of the given rules (implying reflexivity and transitivity).

The following rule extends the rules for [typed references](https://github.com/WebAssembly/function-references/proposals/function-references/Overview.md#subtyping):

* Imported types are subtypes of their bounds
  - `$t <: <constype>`
    - iff `$t = import (sub <constype>)`


## Binary Format

TODO.


## JS API

* Question: should we add `WebAssembly.Type` class to JS API?
  - constructor `new WebAssembly.Type(name)` creates unique abstract type
