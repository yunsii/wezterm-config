// picker.go — Picker interface and self-registration table. Each
// subcommand lives in its own cmd_*.go and registers itself via
// init() so adding a new picker is a single-file change with no edit
// to a central dispatch switch.
package main

import (
	"fmt"
	"os"
)

// Picker is the contract every subcommand implements. Run takes the
// args after the subcommand name (os.Args[2:]) and returns the process
// exit code. Each picker owns its own arg schema, TSV format, key
// handling, and render layout — the helpers in scaffold.go cover only
// the parts that are genuinely identical across all of them.
type Picker interface {
	Name() string
	Run(args []string) int
}

var registry = map[string]Picker{}

func register(p Picker) {
	name := p.Name()
	if _, dup := registry[name]; dup {
		panic(fmt.Sprintf("picker: duplicate registration for %q", name))
	}
	registry[name] = p
}

func dispatchSubcommand(name string, args []string) int {
	p, ok := registry[name]
	if !ok {
		fmt.Fprintf(os.Stderr, "picker: unknown subcommand %q\n", name)
		return 2
	}
	return p.Run(args)
}
