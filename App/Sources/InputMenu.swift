import UIKit
import WebKit
import OptOutKitCore

/// The page every flow shows, with one addition: long-pressing a text box offers "My details", with everything the app knows about the person
/// (names, emails, phones, addresses, birth date) to put into that box. It is for the box the person is on; nothing else on the page changes.
/// Solve and send, the guide and Email links all show this web view, so all three get it. The monthly run shows nothing, so nothing is offered.
final class InputMenuWebView: WKWebView {
    /// The details to offer: set once by the app, read each time the menu opens. Nil or empty offers nothing.
    nonisolated(unsafe) static var details: () -> [DetailGroup] = { [] }

    /// True while the cursor is in a box that takes text, kept by a script on the page (the menu is built before a script could be asked).
    var textBoxFocused = false

    static let focusMessage = "ookFocus"
    /// Reports when a text box gains or loses the cursor, from any frame.
    static let focusScript = """
    (function(){
      function editable(e){ if(!e) return false; var t=(e.tagName||'').toLowerCase();
        if(t==='textarea') return !e.readOnly && !e.disabled;
        if(t==='input'){ var k=(e.type||'text').toLowerCase(); return !e.readOnly && !e.disabled && ['text','email','tel','search','url','number','date','password'].indexOf(k)>=0; }
        return !!e.isContentEditable; }
      function report(){ try{ webkit.messageHandlers.ookFocus.postMessage(editable(document.activeElement)); }catch(e){} }
      document.addEventListener('focusin',report,true);
      document.addEventListener('focusout',function(){ setTimeout(report,0); },true);
    })();
    """

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard textBoxFocused, builder.system == .context else { return }
        let groups = Self.details()
        guard !groups.isEmpty else { return }
        let menus = groups.map { group in
            UIMenu(title: Self.title(group.kind), children: group.values.map { value in
                UIAction(title: value) { [weak self] _ in self?.put(value) }
            })
        }
        builder.insertChild(UIMenu(title: Loc.t("My details"), image: UIImage(systemName: "person.text.rectangle"), children: menus), atStartOfMenu: .standardEdit)
    }

    static func title(_ kind: DetailKind) -> String {
        switch kind {
        case .name: return Loc.t("Name")
        case .email: return Loc.t("Email")
        case .phone: return Loc.t("Phone")
        case .address: return Loc.t("Address")
        case .birthdate: return Loc.t("Birth date")
        }
    }

    /// Types the value into the box the cursor is in, the way the form filler does, so a page that watches its boxes (React, Angular) sees it.
    func put(_ value: String) {
        let literal = (try? String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let js = """
        (function(v){ var el=document.activeElement; while(el&&el.shadowRoot&&el.shadowRoot.activeElement) el=el.shadowRoot.activeElement; if(!el) return false;
          if(el.isContentEditable){ document.execCommand('selectAll'); document.execCommand('insertText',false,v); return true; }
          var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
          var d=Object.getOwnPropertyDescriptor(proto,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
          el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); return true; })(\(literal));
        """
        evaluateJavaScript(js, completionHandler: nil)
    }
}

final class FocusReporter: NSObject, WKScriptMessageHandler {
    weak var view: InputMenuWebView?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let on = message.body as? Bool { view?.textBoxFocused = on }
    }
}
