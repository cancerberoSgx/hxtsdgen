#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
using haxe.macro.Tools;
using StringTools;

enum ExposeKind {
    EClass(c:ClassType);
    EMethod(c:ClassType, cf:ClassField);
}

class TypeScriptDeclarationGenerator {
    static inline var HEADER = "// Generated by Haxe TypeScript Declaration Generator :)";

    static function use() {
        var outJS = Compiler.getOutput();
        var outDTS = Path.withoutExtension(outJS) + ".d.ts";

        Context.onGenerate(function(types) {
            var exposed = [];
            for (type in types) {
                switch (type.follow()) {
                    case TInst(_.get() => cl, _):
                        if (cl.meta.has(":expose"))
                            exposed.push(EClass(cl));
                        for (f in cl.statics.get()) {
                            if (f.meta.has(":expose"))
                                exposed.push(EMethod(cl, f));
                        }
                    default:
                }
            }
            if (exposed.length == 0) {
                sys.io.File.saveContent(outDTS, HEADER + "\n\n// No types were @:expose'd.\n// Read more at http://haxe.org/manual/target-javascript-expose.html");
            } else {
                Context.onAfterGenerate(function() {
                    var declarations = [HEADER];
                    for (e in exposed) {
                        switch (e) {
                            case EClass(cl):
                                declarations.push(generateClassDeclaration(cl));
                            case EMethod(cl, f):
                                declarations.push(generateFunctionDeclaration(cl, f));
                        }
                    }
                    sys.io.File.saveContent(outDTS, declarations.join("\n\n"));
                });
            }
        });
    }

    static function getExposePath(m:MetaAccess):Array<String> {
        switch (m.extract(":expose")) {
            case []: throw "no @:expose meta!"; // this should not happen
            case [{params: []}]: return null;
            case [{params: [macro $v{(s:String)}]}]: return s.split(".");
            case [_]: throw "invalid @:expose argument!"; // probably handled by compiler
            case _: throw "multiple @:expose metadata!"; // is this okay?
        }
    }

    static function wrapInNamespace(exposedPath:Array<String>, fn:String->String->String):String {
        var name = exposedPath.pop();
        return if (exposedPath.length == 0)
            fn(name, "");
        else
            'declare namespace ${exposedPath.join(".")} {\n${fn(name, "\t")}\n}';
    }

    static function renderDoc(doc:String, indent:String):String {
        var parts = [];
        parts.push('$indent/**');
        var lines = doc.split("\n");
        for (line in lines) {
            line = line.trim();
            if (line.length > 0)
                parts.push('$indent * $line');
        }
        parts.push('$indent */');
        return parts.join("\n");
    }

    static function generateFunctionDeclaration(cl:ClassType, f:ClassField):String {
        var exposePath = getExposePath(f.meta);
        if (exposePath == null)
            exposePath = cl.pack.concat([cl.name, f.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];
            if (f.doc != null)
                parts.push(renderDoc(f.doc, indent));

            switch [f.kind, f.type] {
                case [FMethod(_), TFun(args, ret)]:
                    var prefix =
                        if (indent == "") // so we're not in a namespace (meh, this is hacky)
                            "declare function "
                        else
                            "function ";
                    parts.push(renderFunction(name, args, ret, f.params, indent, prefix));
                default:
                    throw new Error("This kind of field cannot be exposed to JavaScript", f.pos);
            }

            return parts.join("\n");
        });
    }

    static function renderFunction(name:String, args:Array<{name:String, opt:Bool, t:Type}>, ret:Type, params:Array<TypeParameter>, indent:String, prefix:String):String {
        var args = args.map(convertArg);
        var tparams = renderTypeParams(params);
        return '$indent$prefix$name$tparams(${args.join(", ")}): ${convertTypeRef(ret)};';
    }

    static function renderTypeParams(params:Array<TypeParameter>):String {
        return
            if (params.length == 0) ""
            else "<" + params.map(function(t) return return t.name).join(", ") + ">";
    }

    static function generateClassDeclaration(cl:ClassType):String {
        var exposePath = getExposePath(cl.meta);
        if (exposePath == null)
            exposePath = cl.pack.concat([cl.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];

            if (cl.doc != null)
                parts.push(renderDoc(cl.doc, indent));

            var tparams = renderTypeParams(cl.params);
            parts.push('$indent${if (indent == "") "declare " else ""}class $name$tparams {');

            {
                var indent = indent + "\t";

                if (cl.constructor != null) {
                    var ctor = cl.constructor.get();
                    if (ctor.isPublic)
                        if (ctor.doc != null)
                            parts.push(renderDoc(ctor.doc, indent));
                        switch (ctor.type) {
                            case TFun(args, _):
                                var args = args.map(convertArg);
                                parts.push('${indent}constructor(${args.join(", ")});');
                            default:
                                throw "wtf";
                        }
                }

                function addField(field:ClassField, isStatic:Bool) {
                    if (field.isPublic) {
                        if (field.doc != null)
                            parts.push(renderDoc(field.doc, indent));

                        var prefix = if (isStatic) "static " else "";

                        switch [field.kind, field.type] {
                            case [FMethod(_), TFun(args, ret)]:
                                parts.push(renderFunction(field.name, args, ret, field.params, indent, prefix));

                            case [FVar(_,write), _]:
                                switch (write) {
                                    case AccNo|AccNever:
                                        prefix += "readonly ";
                                    default:
                                }
                                parts.push('$indent$prefix${field.name}: ${convertTypeRef(field.type)};');

                            default:
                        }
                    }
                }

                for (field in cl.fields.get()) {
                    addField(field, false);
                }

                for (field in cl.statics.get()) {
                    addField(field, true);
                }
            }

            parts.push('$indent}');
            return parts.join("\n");
        });
    }

    static function convertArg(arg:{name:String, opt:Bool, t:Type}):String {
        var argString = arg.name;
        if (arg.opt) argString += "?";
        argString += ": " + convertTypeRef(arg.t);
        return argString;
    }

    static function convertTypeRef(t:Type):String {
        var t = t.followWithAbstracts();
        return switch (t.toString()) {
            case "String": "string";
            case "Int" | "Float": "number";
            case "Bool": "boolean";
            case "Void": "void";
            case other:
                switch (t) {
                    case TInst(_.get() => {name: name, kind: KTypeParameter(_)}, _):
                        name;
                    default:
                        other;
                }
        }
    }
}
#end
