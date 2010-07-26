Overview
========

**Moio** (Multiple-Occurrence I/O) is a library that provides
composable abstractions for event-driven programming: producers and
actors. The **Producer** monad is a generalisation of the **IO** monad
that returns not just a single result *at the end* of its execution,
but a potentially infinite stream of values distributed over time
*during* its life. The **Actor** category is in essence a producer
transformer, and it can also be seen as a further generalisation of
**Producer**, because it can make use of an incoming stream of events
besides outputting a stream. Given a **Producer a** and an **Actor a
b**, we can construct a **Producer b** by feeding the output of the
first producer into the actor. Thanks to the monadic interface, the
structure of the event stream network can be entirely dynamic.

Contents
========

This repository contains three main directories:

* lib: the cabalised, haddock-friendly library
* examples: some application code built on top of the library with
  extra dependencies
* model: a pure implementation of the library for testing purposes
