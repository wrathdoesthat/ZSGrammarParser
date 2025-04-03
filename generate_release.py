import sys, subprocess, shutil, os

# added name to plugin - extra arguments
outputs = {
    "AllSnippets": [],
    "NoSnippets": ["-disable-snippets"],
    "NoAssetSnippets": ["-disable-asset-snippets"]
}

def main():
    if len(sys.argv) == 1:
        print("Usage: py generate_release.py PATH_TO_DOCUMENTATION")
        return
    
    documentation_path = sys.argv[1]
    if not os.path.exists(documentation_path):
        print(documentation_path, " does not exist")
        return
    
    if not os.path.exists("./ZSGrammarParser.exe"):
        print("./ZSGrammarParser.exe doesnt exist (forget to compile?)")
        return
    
    if os.path.exists("./Release"):
        shutil.rmtree("./Release")
        
    os.mkdir("./Release")
        
    for output in outputs:
        subprocess_args = ["./ZSGrammarParser.exe", documentation_path] + outputs[output]
        subprocess.run(subprocess_args)
        shutil.make_archive("./Release/" + output, "zip", "./ZSGrammar")
    
    shutil.rmtree("./ZSGrammar")
        
if __name__ == "__main__":
    main()