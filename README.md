# Lemon Pie

Lemon pie is a library to build [Gemini](https://gemini.circumlunar.space/) servers. It's implemented in [Zig](https://ziglang.org) 
and its main goal is to provide the building blocks with enough customizability to either depend on its implementation
to do the work for you, or provide the access to do it yourself. This allows us to support all use cases if you're willing
to handle some of the checks yourself.

As Gemini is a very small protocol with a small specification, it allows us to implement the entire specification
without relying on any other library apart from TLS support.

To access Gemini, you'll need a client which supports its protocol.
Some examples are:
- [Kristall](https://github.com/MasterQ32/kristall) [GUI, C++ (QT)]
- [Amfora](https://github.com/makeworld-the-better-one/amfora) [TUI, Go]
- [Bombadillo](https://rawtext.club/~sloum/bombadillo.html) [TUI, Go, VIM keybindings]

## Status
Lemon Pie is still very much work-in-progress. TLS 1.2 or higher is a requirement for Gemini and must
be implemented to match the Gemini specification. The goal is to add server support to [IguanaTLS](https://github.com/alexnask/iguanaTLS)
and then leverage this library for TLS support.

A secondary goal is to provide a set of tools to make it easier to write and serve Gemini content.
The [specification](https://gemini.circumlunar.space/docs/specification.html) describes the Gemini mime-type and how
content is laid out. A tool could be a simple formatter to write such content.

## Example
An example will be provided once the API is more stable.
This requires us to support TLS first.
