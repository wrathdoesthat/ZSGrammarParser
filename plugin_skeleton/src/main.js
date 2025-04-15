const vscode = require("vscode")
const fs = require("fs")

let outputChannel;

async function generateEmptyMod() { 
    let curFolder = vscode.workspace.workspaceFolders[0].uri.fsPath
    let curFolderFiles = fs.readdirSync(curFolder)

    if(curFolderFiles.length != 0) {
        vscode.window.showErrorMessage("Directory must be empty to generate an empty mod")
        return
    }

    // TODO: even bother with this? i might just make them edit the file manually instead
    let modName = await vscode.window.showInputBox({ title: "Mod name", placeholder: "Mod name", value: "Name" })
    if (!modName)
        return

    let modDescription = await vscode.window.showInputBox({ title: "Mod description", placeholder: "Mod description", value: "Description" })
    if (!modDescription) {
        modDescription = "Placeholder"
    }

    let modAuthor = await vscode.window.showInputBox({ title: "Mod author", placeholder: "Mod author", value: "Author" })
    if (!modAuthor)
        return

    // lol
    const metaFileTemplate =
`[mod]
name=${modName}
description=${modDescription}
version=v0.0.1
author=${modAuthor}
[leave blank]`

    fs.writeFileSync(curFolder + "/meta.ini", metaFileTemplate)
    fs.writeFileSync(curFolder + "/init.script", "-- Your code here :)")
    //fs.mkdirSync(curFolder + "/scripts")
}

function activate(context) {
    context.subscriptions.push(vscode.commands.registerCommand("zsmoddingtools.generateEmptyMod", generateEmptyMod))
    //outputChannel = vscode.window.createOutputChannel("ZSModdingtools")
}

module.exports = {
    activate
}