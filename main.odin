#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:os/os2"
import "core:strings"
import "core:text/scanner"
import "core:path/filepath"

CLIArguments :: struct {
	path_to_documentation:  string `args:"pos=0,required" usage:"Path to game modding documentation folder."`,
	disable_snippets:       bool `usage:"Set this flag if you want to disable all snippets (function and asset)"`,
	disable_asset_snippets: bool `usage:"Set this flag if you want to disable the asset snippets"`,
	clean: bool `usage:"Set to delete the ZSGrammar folder"`
}

// These use a different style of table in the documentation but since they have common prefixes
// just handwriting them and searching exposed values is fine
constant_prefixes: []string = {
	"MAP_",
	"DIALOGUE_TYPE_",
	"FACTION_REP_"
}

SnippetType :: enum {
	Function, // 
}

SnippetDef :: struct {
	prefix: string,
	body:   string, 
}

generate_function_snippet :: proc(name: string, fn_doc_paths: map[string]string, snips: ^map[string]SnippetDef) {
	arguments: [dynamic]string

	if name in fn_doc_paths {
		doc_path := fn_doc_paths[name]
		file_data, read_err := os2.read_entire_file_from_path(doc_path, context.temp_allocator)
		if read_err != os2.ERROR_NONE {
			fmt.println("Error reading fn doc at path", name)
			return
		}

		data_as_str := string(file_data)
		searching_for := strings.concatenate({name, "("})
		idx := strings.index(data_as_str, searching_for)

		// couldnt find function name in documentation paths
		if idx == -1 {return}

		scanner_substr := data_as_str[idx + len(name):idx + 2048]

		s: scanner.Scanner
		s = scanner.init(&s, scanner_substr)^

		// skip (
		scanner.scan(&s)

		// Function has arguments because next character isnt closing bracket
		if (scanner.peek(&s) != ')') {
			for {
				scanned := scanner.scan(&s)
	
				// We have a default argument in the documentation
				// Maybe these could be used later somehow but for nowe we 
				if scanner.peek(&s) == '=' {
					append(&arguments, strings.clone(scanner.token_text(&s)))
	
					// Skip = part of default arguments
					scanner.scan(&s)
	
					// If default argument was an array scan until the end
					if scanner.peek(&s) == '[' {
						for scanner.scan(&s) != ']' {}
					} else { // Skip default argument
						scanner.scan(&s)
					}

					// The default part was the last part of our arguments just leave
					if scanner.peek(&s) == ')' {
						break
					}
					else { // We have another argument probably continue parsing
						continue
					}
				}
	
				// parsed a full argument
				if scanner.peek(&s) == ',' {
					append(&arguments, strings.clone(scanner.token_text(&s)))
					continue
				}
	
				// Reached the end of arguments
				if scanner.peek(&s) == ')' {
					append(&arguments, strings.clone(scanner.token_text(&s)))
					break
				}
			}
		}
	}

	argbuf: [1024]byte
	argbuilder := strings.builder_from_bytes(argbuf[:])

	for arg, i in arguments {
		strings.write_string(&argbuilder, "${")
		strings.write_int(&argbuilder, i + 1)
		strings.write_string(&argbuilder, ":")
		strings.write_string(&argbuilder, arg)

		if i == len(arguments) - 1 {
			strings.write_string(&argbuilder, "}")
		} else {
			strings.write_string(&argbuilder, "}, ")
		}
	}

	arguments_string := strings.concatenate({"(", strings.to_string(argbuilder), ")"})

	snips[name] = SnippetDef {
		prefix = strings.concatenate({name, "()"}),
		body   = strings.concatenate({name, arguments_string}),
	}

	fmt.println(strings.concatenate({name, arguments_string}))
}

main :: proc() {
	context.allocator = context.temp_allocator

	cli_args: CLIArguments
	flags.parse_or_exit(&cli_args, os2.args)

	// Remove any old generated plugin
	if os2.exists("./ZSGrammar/") {
		os2.remove_all("./ZSGrammar/")
		
		if cli_args.clean {return}
	}

	// copy over our skeleton plugin
	plugin_dir_create_err := os2.make_directory("./ZSGrammar/")
	if plugin_dir_create_err != os2.ERROR_NONE {
		fmt.println("Error creating ./ZSGrammar", plugin_dir_create_err)
		return
	}

	w := os2.walker_create("./plugin_skeleton")
	for fi in os2.walker_walk(&w) {
		if path, err := os2.walker_error(&w); err != nil {
			fmt.eprintfln("failed walking %s: %s", path, err)
			continue
		}
		
		new_path_string, _ := strings.replace(fi.fullpath, "plugin_skeleton", "ZSGrammar", -1) 
		new_path, _ := filepath.from_slash(new_path_string)

		if fi.type == .Directory {
			os2.make_directory(new_path)
		} else {
			os2.copy_file(new_path, fi.fullpath)
		}
	}

	if !cli_args.disable_snippets {
		exposed_values_path := strings.concatenate({cli_args.path_to_documentation, "/exposed_values.txt"})
		exposed_value_data, err := os2.read_entire_file_from_path(exposed_values_path, context.allocator)

		if err != os2.ERROR_NONE {
			fmt.println("Error reading", exposed_values_path, "wrong documentation path or its missing?")
			return
		}

		// Get function filename paths
		fn_doc_paths: map[string]string
		w := os2.walker_create(strings.concatenate({cli_args.path_to_documentation, "/Functions"}))
		for fi in os2.walker_walk(&w) {
			if path, err := os2.walker_error(&w); err != nil {
				fmt.eprintfln("failed walking %s: %s", path, err)
				continue
			}

			if fi.type == .Directory {
				continue
			}

			split_path := strings.split(fi.name, ".")
			fn_doc_paths[strings.clone(split_path[0])] = strings.clone(fi.fullpath)
		}

		snippet_map: map[string]SnippetDef
		parsing_functions := true

		it := string(exposed_value_data)
		for line in strings.split_lines_iterator(&it) {
			// Seems like functions and prefixed constants only appear before this
			if strings.index(line, "YYInternalObject") != -1 {
				parsing_functions = false
				continue
			}

			// there are some names like object23432 sprite443 not sure what they are but discard
			if strings.starts_with(line, "Sprite2058") || strings.starts_with(line, "object") || strings.starts_with(line, "sprite") {
				continue
			}

			if parsing_functions {
				was_constant := false
				for prefix in constant_prefixes {
					if strings.starts_with(line, prefix) {
						snippet_map[line] = SnippetDef {
							prefix = line,
							body   = strings.clone(line),
						}
						was_constant = true
						break
					}
				}
				if was_constant {continue}

				// Cant be a function likely an "asset" or enum
				if strings.index(line, "_") != -1 {
					continue
				}

				generate_function_snippet(line, fn_doc_paths, &snippet_map)
			} else {
				// Asset snippets break if disabled
				if cli_args.disable_asset_snippets {break} 
				snippet_map[line] = SnippetDef {
					prefix = line,
					body   = strings.concatenate({"\"", line, "\""}),
				}
			}
		}

		snippet_json, marshal_err := json.marshal(snippet_map, {pretty = true})
		err2 := os2.write_entire_file("ZSGrammar/snippets/snippets.json", snippet_json[:])
	}

	fmt.println("Plugin successfully generated at ./ZSGrammar just move it (not plugin_skeleton) into your vscode plugins folder and any time you open a .meow or .script file it should load!")

	free_all(context.allocator)
}