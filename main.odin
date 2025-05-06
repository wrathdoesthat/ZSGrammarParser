#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:os/os2"
import "core:strings"
import "core:text/scanner"
import "core:sys/windows"
import "core:encoding/xml"

CLI_Arguments :: struct {
	path_to_documentation:  string `args:"pos=0,required" usage:"Path to game modding documentation folder."`,
	output_dir:             string `usage:Changes the directory the plugin is output to (note: Deletes any old ZSModdingTools folder in this directory too)`,

	disable_snippets:       bool `usage:"Set to disable all snippets (function and asset)"`,
	disable_asset_snippets: bool `usage:"Set to disable only the asset snippets"`,

	// Debug only
	verbose: bool `usage:"Set to enable extra information output (for debugging)"`,
}

Snippet_Def :: struct {
	prefix: string,
	body:   string, 
}

Argument_Parsing_Error :: enum {
	None,
	No_Arguments, // Not always an actual error
	Not_Documented, 
	Failed_To_Find_Body, 
}

ignored_function_paths : []string = {
	// Handled by gamemaker snippets
	"Structs", 
	"Math and Randoms", 
	"Input", 
	"Drawing",
	"Arrays",
	"Particles",

	// Not meant to exist
	"Items/Headsets",
}

vb_print :: proc(args: ..any) {
	if cli_args.verbose do fmt.println(..args)
}

dir_files_into_map :: proc(path: string, files: ^map[string]string) {
	fn_walker := os2.walker_create(path)

	for fi in os2.walker_walk(&fn_walker) {
		if walked_path, err := os2.walker_error(&fn_walker); err != nil {
			fmt.println("failed walking", walked_path, err)
			continue
		}

		if strings.index(fi.name, "(UNFINISHED)") != -1 || strings.index(fi.name, "(IN PROGRESS)") != -1 {
			continue
		}

		is_dir := fi.type == .Directory

		for walked_path in ignored_function_paths {
			if fi.name == walked_path {
				if is_dir do os2.walker_skip_dir(&fn_walker)
				continue
			}
		}

		if is_dir {continue}

		// remove .html from name
		filename, _ := os2.split_filename(fi.name)
		files[strings.clone(filename)] = strings.clone(fi.fullpath)
	}
}

get_function_arguments :: proc(name: string, path: string, cli_args: CLI_Arguments) -> ([dynamic]string, Argument_Parsing_Error) {
	arguments: [dynamic]string

	file_data, read_err := os2.read_entire_file_from_path(path, context.allocator)
	defer delete(file_data)
	if read_err != os2.ERROR_NONE {
		fmt.println("Error reading fn doc at path", path)
		return {}, .None
	}

	data := string(file_data)
	if strings.index(data, "Documentation coming soon.") != -1 {
		return {}, .Not_Documented
	}

	searching_for := strings.concatenate({name, "("})
	defer delete(searching_for)

	starting_idx := strings.index(data, searching_for)
	if starting_idx == -1 {
		return {}, .Failed_To_Find_Body
	}

	scanner_substr := data[starting_idx : starting_idx + 256]

	s := new(scanner.Scanner)
	defer free(s)

	s = scanner.init(s, scanner_substr)

	for {
		scanned := scanner.scan(s)

		if scanned == scanner.Ident {
			if scanner.peek_token(s) == '=' {
				append(&arguments, strings.clone(scanner.token_text(s)))
				scanner.scan(s) // Skip =

				// If default argument was an array scan until the end
				if scanner.peek(s) == '[' {
					// we can just discard everything inside of the array
					for scanner.scan(s) != ']' {}
				} else { // Skip default argument
					scanner.scan(s)
				}

				continue
			}

			if scanner.peek_token(s) == ',' {
				append(&arguments, strings.clone(scanner.token_text(s)))
				continue
			}

			if scanner.peek_token(s) == ')' {
				append(&arguments, strings.clone(scanner.token_text(s)))
				break
			}
		}

		if scanned == ')' {break}
	}

	if len(arguments) == 0 {
		return {}, .No_Arguments
	} else {
		return arguments, .None
	}
}

build_function_snippet :: proc(name: string, snippets: ^map[string]Snippet_Def, arguments: [dynamic]string) {
	argbuf: [1024]byte
	argbuilder := strings.builder_from_bytes(argbuf[:])

	// Both builds the arguments and frees them
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

		delete(arg)
	}

	arguments_string := strings.concatenate({"(", strings.to_string(argbuilder), ")"})

	snippets[strings.clone(name)] = Snippet_Def {
		prefix = strings.concatenate({name, "()"}),
		body   = strings.concatenate({name, arguments_string}),
	} 

	delete(arguments_string)
}

parse_function :: proc(name: string, path: string, snippets: ^map[string]Snippet_Def) {
	arguments, parse_err := get_function_arguments(name, path, cli_args)
	#partial switch parse_err {
		case .Not_Documented: {
			vb_print("undocumented:", name)
		}
		case .Failed_To_Find_Body: {
			vb_print("failed to find body for:", name)
		}
		case .No_Arguments: {
			vb_print("no arguments:", name)
		}
	}

	// Function had no arguments so we just write an empty body
	if len(arguments) == 0 {
		snippets[strings.clone(name)] = Snippet_Def {
			prefix = strings.concatenate({name, "()"}),
			body   = strings.concatenate({name, "()"}),
		}
		return
	}

	build_function_snippet(name, snippets, arguments)	
	delete(arguments)
}

parse_constants_and_macros :: proc(name: string, path: string, snippets: ^map[string]Snippet_Def) {
	file_data, read_err := os2.read_entire_file_from_path(path, context.allocator)
	defer delete(file_data)
	if read_err != os2.ERROR_NONE {
		fmt.println("Error reading fn doc at path", path)
		return
	}

	data := string(file_data)
	
	// the table html is valid xml as well :)
	table_begin := strings.index(data, "<tbody>")
	table_end := strings.index(data, "</tbody>") + len("</tbody>")
	
	original_table := data[table_begin : table_end]
	
	// Some use a break tag this breaks the parsing
	cleaned_table1, _ := strings.remove_all(original_table, "<br>", context.temp_allocator)

	// some use strong tags this complicates the parsing so i just remove it
	cleaned_table2, _ := strings.remove_all(cleaned_table1, "<strong>", context.temp_allocator)
	table, _ := strings.remove_all(cleaned_table2, "</strong>", context.temp_allocator)

	doc, parse_err := xml.parse(table)
	if parse_err != .None {
		fmt.println("Error parsing xml table at", path, parse_err)
	}

	idx := 0
	for {
		item, found := xml.find_child_by_ident(doc, 0, "tr", idx)
		if !found {break}

		child, _ := xml.find_child_by_ident(doc, item, "td")
		value := doc.elements[child].value[0].(string)
		
		final_value := value
		if strings.index(value, "“") != -1 {
			vb_print(value, "had bad quotes")
			
			fixed1, _ := strings.replace_all(value, "“", "\"", context.temp_allocator)
			fixed2, _ := strings.replace_all(fixed1, "”", "\"", context.temp_allocator)

			final_value = fixed2
		}

		unquoted_name, _ := strings.remove_all(final_value, "\"", context.temp_allocator)

		if unquoted_name not_in snippets {
			snippets[strings.clone(unquoted_name)] = Snippet_Def {
				prefix = strings.clone(final_value),
				body   = strings.clone(final_value),
			}
		}

		idx += 1
	}

	xml.destroy(doc)
	free_all(context.temp_allocator)
}

cli_args : CLI_Arguments

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.println(len(track.allocation_map), "allocations not freed")
				for _, entry in track.allocation_map {
					fmt.println(entry.size, "bytes at", entry.location)
				}
			}

			mem.tracking_allocator_destroy(&track)
		}
	}

	flags.parse_or_exit(&cli_args, os2.args)

	extension_path := strings.clone(".\\ZSModdingTools")
	if len(cli_args.output_dir) > 0 {
		delete(extension_path)

		cleaned_path, _ := os2.clean_path(cli_args.output_dir, context.allocator)	
		if !os2.exists(cleaned_path) {
			fmt.println("Output path doesnt exist", cleaned_path)
			return
		}

		extension_path = strings.concatenate({cleaned_path, "\\ZSModdingTools"})
		delete(cleaned_path)
	}

	defer delete(extension_path)
	
	// Remove any old generated plugin
	if os2.exists(extension_path) {
		conv_str := windows.utf8_to_wstring(extension_path, context.allocator)
		op_struct := windows.SHFILEOPSTRUCTW{
			hwnd = nil,
			wFunc = windows.FO_DELETE,
			fFlags = windows.FOF_ALLOWUNDO | windows.FOF_NO_UI,
			pFrom = conv_str,
		}
		windows.SHFileOperationW(&op_struct)
		free(conv_str)
	}

	// copy over our skeleton plugin
	{
		plugin_dir_create_err := os2.make_directory(extension_path)
		if plugin_dir_create_err != os2.ERROR_NONE {
			fmt.println("Error creating", extension_path, plugin_dir_create_err)
			return
		}

		fmt.println("Writing extension skeleton to", extension_path)
		skeleton_walker := os2.walker_create(".\\plugin_skeleton")
		for fi in os2.walker_walk(&skeleton_walker) {
			if path, err := os2.walker_error(&skeleton_walker); err != nil {
				fmt.println("failed walking", path, err)
				continue
			}

			non_rel_path, _ := strings.remove(fi.fullpath, ".\\plugin_skeleton", 1, context.temp_allocator)
			full_path := strings.concatenate({extension_path, non_rel_path}, context.temp_allocator)

			if fi.type == .Directory {
				os2.make_directory(full_path)
			} else {
				os2.copy_file(full_path, fi.fullpath)
			} 
		}

		free_all(context.temp_allocator)
	}

	if !cli_args.disable_snippets {
		snippets : map[string]Snippet_Def

		// Gamemaker snippets we hand did
		{
			gm_snippets : map[string]Snippet_Def
			gm_snippet_data, read_err := os2.read_entire_file_from_path(".\\builtin_snippets\\gamemaker.jsonc", context.temp_allocator)
			if read_err != os2.ERROR_NONE {
				fmt.println("Error opening .\\builtin_snippets\\gamemaker.jsonc", read_err)
				return
			}
		
			if err := json.unmarshal(gm_snippet_data, &gm_snippets, allocator = context.temp_allocator); err != nil {
				fmt.println("Error loading .\\builtin_snippets\\gamemaker.jsonc", err)
				return
			}

			for name in gm_snippets {
				gm_snippet := gm_snippets[name]
				snippets[strings.clone(name)] = {
					prefix = strings.clone(gm_snippet.prefix),
					body = strings.clone(gm_snippet.body),
				}
			}

			delete(gm_snippets)
			free_all(context.temp_allocator)
		}

		// Documentation functions
		fn_doc_paths: map[string]string
		fns_path := strings.concatenate({cli_args.path_to_documentation, "\\Functions"})
		dir_files_into_map(fns_path, &fn_doc_paths)
		delete(fns_path)

		defer {
			for k in fn_doc_paths {
				delete(fn_doc_paths[k])
				delete(k)
			}
			delete(fn_doc_paths)
		}

		// Parse functions
		for name in fn_doc_paths {
			path := fn_doc_paths[name]
			parse_function(name, path, &snippets)
		}

		// Documentation macros and constants
		if !cli_args.disable_asset_snippets {
			macro_doc_paths: map[string]string
			macros_path := strings.concatenate({cli_args.path_to_documentation, "\\Constants and Macros"})
			dir_files_into_map(macros_path, &macro_doc_paths)
			delete(macros_path)

			defer {
				for k in macro_doc_paths {
					delete(macro_doc_paths[k])
					delete(k)
				}
				delete(macro_doc_paths)
			}

			for name in macro_doc_paths {
				path := macro_doc_paths[name]

				// TODO: this one has multiple tables ill have to figure this out
				if name == "Pre-Existing Objects" {continue}

				parse_constants_and_macros(name, path, &snippets)
			}
		}

		snippet_json, _ := json.marshal(snippets, {pretty = true}, context.temp_allocator)
		snippet_path := strings.concatenate({extension_path, "\\snippets\\snippets.json"}, context.temp_allocator)
		
		fmt.println("Writing snippets to", snippet_path)
		err := os2.write_entire_file(snippet_path, snippet_json[:])
		if err != os2.ERROR_NONE {
			fmt.println("Error writing the snippet json to the generated plugin", err)
			return
		}
		free_all(context.temp_allocator)

		for k in snippets {
			snippet := snippets[k]
			delete(snippet.body)
			delete(snippet.prefix)
			delete(k)
		}

		delete(snippets)
	}
	
	if len(cli_args.output_dir) == 0 {
		fmt.println("Plugin successfully generated at", extension_path, "just move it (not plugin_skeleton) into your vscode plugins folder and any time you open a .meow or .script file it should load!")
	} else {
		fmt.println("Plugin successfully generated at", extension_path, "any time you open a .meow or .script file it should load!")
	}
}