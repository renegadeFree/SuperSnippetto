import Foundation

@main
struct ATextMacroTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { if try !condition() { fatalError(message) } } catch { fatalError("\(message): \(error)") }
    }
    static func main() throws {
        func convert(_ source: String) -> String {
            let result = ATextMacroConverter.convert(source)
            check(result.warnings.isEmpty, "Supported macro: \(source): \(result.warnings)")
            return result.text
        }
        func unsupported(_ source: String) {
            let result = ATextMacroConverter.convert(source)
            check(result.text == source && !result.warnings.isEmpty, "Unsupported remains literal: \(source)")
        }
        check(convert("plain <b>text</b> &amp; <atextual>") == "plain <b>text</b> &amp; <atextual>", "Only aText elements converted")
        check(convert("a<atext>|</atext>b") == "a{{cursor}}b", "Legacy caret")
        check(convert("<atext type='caret' contenteditable='false'>|</atext>") == "{{cursor}}", "Caret")
        check(convert("<atext type='clipboard'/>") == "{{clipboard}}", "Self closing XML")
        check(convert("<atext type='clipboard' history='0'>x</atext>") == "{{clipboard}}", "Current clipboard")
        unsupported("<atext type='clipboard' history='1'>x</atext>")
        unsupported("<atext type='clipboard' transforms='abc'>x</atext>")
        unsupported("<atext type='key' mac='36'>return</atext>")
        unsupported("<atext type='mouse' script='Click'>click</atext>")
        unsupported("<atext type='file' path='/tmp/input'>f</atext>")
        unsupported("<atext type='param' name='a'>a</atext>")
        unsupported("<atext type='caret' newoption='1'>x</atext>")
        unsupported("<atext type='caret'><b>|</b></atext>")
        unsupported("<atext type='caret'")
        unsupported("<atext type='caret'>|")
        unsupported("<atext type='caret'><!-- comment --></atext>")
        unsupported("<atext type='caret'><?test data?></atext>")
        let id = UUID().uuidString
        check(convert("<atext type='snippet' guid='\(id.lowercased())'>name</atext>") == "{{snippet:\(id)}}", "GUID canonical reference")
        unsupported("<atext type='snippet' guid='bad'>name</atext>")
        unsupported("<atext type='snippet' guid='\(id)' param0='x'>name</atext>")
        let field = "<atext type='field' flags='4' name='Nome' value='Mario &amp; C'>display</atext>"
        check(convert(field) == "{{field:Nome|Mario & C}}", "Editable field and XML entities")
        let form = field + "/<atext type='field' name='Nome'>Nome</atext>"
        let converted = convert(form)
        check(converted == "{{field:Nome|Mario & C}}/{{var:Nome}}", "Named readonly reference")
        let renderer = TemplateRenderer()
        check(try renderer.render(converted, context: RenderContext()).fields == ["Nome"], "Form asks once")
        check(try renderer.render(converted, context: RenderContext(variables: ["Nome": "Anna"])).text == "Anna/Anna", "Shared value expanded")
        unsupported("<atext type='field' name='missing'>missing</atext>")
        unsupported("<atext type='field' name='Nome' flags='2'>x</atext>")
        unsupported("<atext type='field' name='Nome' flags='5'>x</atext>")
        unsupported("<atext type='field' name='Nome' flags='4' mandatory=''>x</atext>")
        unsupported("<atext type='field' fieldtype2='1' value='sqrt(a)' flags='4'>x</atext>")
        check(convert("<atext type='field' name='Note' value='a&#xA;b' flags='4' lines='3'>n</atext>") == "{{multiline:Note|a\nb}}", "Multiline")
        check(convert("<atext type='field' flags='4' value='default'>x</atext>") == "{{field:Campo aText 1|default}}", "Anonymous prompt")
        let escaped = convert("<atext type='field' flags='4' name='A|B' value='C|D\\E'>x</atext>")
        check(try renderer.render(escaped, context: RenderContext()).fieldSpecs[0].defaultValue == "C|D\\E", "Native argument escaping")
        let choice = convert("<atext type='field' fieldtype2='2' flags='4' name='Tipo' item0='Uno' item1='Due'>menu</atext>")
        check(try renderer.render(choice, context: RenderContext()).fieldSpecs[0].options == ["Uno", "Due"], "Choice items")
        unsupported("<atext type='field' fieldtype2='2' flags='4' name='Tipo' item0='Uno' item2='Tre'>menu</atext>")
        unsupported("<atext type='field' fieldtype2='2' flags='4' name='Tipo' item0='snippet:\(id)'>menu</atext>")
        unsupported("<atext type='field' fieldtype2='3' flags='4' name='Tipo' item0='Uno'>menu</atext>")
        let conflict = ATextMacroConverter.convert(field + "<atext type='field' flags='4' name='Nome' value='Luigi'>n</atext>")
        check(!conflict.warnings.isEmpty, "Conflicting definitions flagged before activation")
        let injection = ATextMacroConverter.convert("Literal {{clipboard}} and <atext>|</atext>")
        check(!injection.warnings.isEmpty && injection.text == "Literal {{clipboard}} and {{cursor}}", "Existing native delimiters flagged")
        let date = ISO8601DateFormatter().date(from: "2026-03-07T12:04:05Z")!
        func dated(_ attributes: String) throws -> String {
            let native = convert("<atext type='datetime' locale='en_US_POSIX' \(attributes)>date</atext>")
            return try renderer.render(native, context: RenderContext(date: date)).text
        }
        // Explicit locale, current calendar zone: compare to Foundation rather than assume host timezone.
        let expected = DateFormatter(); expected.locale = Locale(identifier: "en_US_POSIX"); expected.dateFormat = "yyyy-MM-dd EEEE"
        check(try dated("format='yyyy-MM-dd dddd'") == expected.string(from: date), ".NET weekday converted to Unicode")
        check(try dated("format='yyyy-MM-dd' f0='shift;day:1;'") == "2026-03-08", "Observed relative shift")
        check(try dated("format='d'") == "7", "Non-preset single d stays custom day")
        let standard = DateFormatter(); standard.locale = Locale(identifier: "en_US_POSIX"); standard.dateStyle = .full
        check(try dated("format='D' preset='1'") == standard.string(from: date), "Preset D becomes localized full date")
        check(try dated("format='yyyy &quot;at&quot; HH:mm'").contains("2026 at"), "Quoted date literal")
        check(try dated("format='yyyy &quot;&apos;&quot;'") == "2026 '", "Literal apostrophe conversion")
        unsupported("<atext type='datetime' format='D'>x</atext>")
        unsupported("<atext type='datetime' format='weekofyear'>x</atext>")
        unsupported("<atext type='datetime' format='yyyy' f0='findweekday:0;type:0;'>x</atext>")
        unsupported("<atext type='datetime' format='yyyy' f0='shift;day:1;' f1='shift;day:2;'>x</atext>")
        unsupported("<atext type='datetime' format='fffffff'>x</atext>")
        unsupported("<atext type='datetime' format='%d'>x</atext>")
        unsupported("<atext type='datetime' format='yyyy' reference='field'>x</atext>")
        let large = "<atext type='caret'>" + String(repeating: "x", count: 65_536) + "</atext>"
        unsupported(large)
        print("ATextMacroTests: \(checks) checks passed")
    }
}
