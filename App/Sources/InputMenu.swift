import UIKit
import WebKit
import OptOutKitCore

/// The page every flow shows, with one addition: long-pressing a text box offers "My details", with everything the app knows about the person
/// (names, emails, phones, addresses, birth date) to put into that box. It is for the box the person is on; nothing else on the page changes.
/// Solve and send, the guide and Email links all show this web view, so all three get it. The monthly run shows nothing, so nothing is offered.
final class InputMenuWebView: WKWebView, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
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

    /// Shown by this view itself on an empty box, where the system offers no menu of its own to add to.
    private var emptyBoxMenu: UIEditMenuInteraction?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction); emptyBoxMenu = interaction
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.5; press.cancelsTouchesInView = false; press.delegate = self
        addGestureRecognizer(press)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The system menu comes with text in the box. An empty box gets none, so a long press there asks the page whether the touch is on an empty text box,
    /// puts the cursor in it, and shows "My details" once the finger is lifted.
    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .ended, !Self.details().isEmpty else { return }
        let point = g.location(in: self)
        let js = """
        (function(x,y){ var vv=window.visualViewport, s=vv?vv.scale:1, ox=vv?vv.offsetLeft:0, oy=vv?vv.offsetTop:0;
          var el=document.elementFromPoint(ox+x/s, oy+y/s); while(el&&el.shadowRoot){ var inner=el.shadowRoot.elementFromPoint(ox+x/s, oy+y/s); if(!inner||inner===el) break; el=inner; }
          if(!el) return false; var t=(el.tagName||'').toLowerCase(), ok=false;
          if(t==='textarea') ok=!el.readOnly&&!el.disabled;
          else if(t==='input'){ var k=(el.type||'text').toLowerCase(); ok=!el.readOnly&&!el.disabled&&['text','email','tel','search','url','number','password'].indexOf(k)>=0; }
          else ok=!!el.isContentEditable;
          if(!ok) return false; var v=el.isContentEditable?(el.innerText||''):el.value; if(v&&v.length) return false;
          el.focus(); return true; })(\(point.x),\(point.y));
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, result as? Bool == true else { return }
            self.textBoxFocused = true
            // The page may zoom to the box as it takes the cursor: once it has settled, the menu is shown over the box where it ended up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let rect = """
                (function(){ var e=document.activeElement, vv=window.visualViewport; if(!e||!vv) return null; var r=e.getBoundingClientRect();
                  return [(r.left+r.width/2-vv.offsetLeft)*vv.scale, (r.top-vv.offsetTop)*vv.scale]; })();
                """
                self.evaluateJavaScript(rect) { found, _ in
                    var at = point
                    if let xy = found as? [Double], xy.count == 2, self.bounds.contains(CGPoint(x: xy[0], y: xy[1])) { at = CGPoint(x: xy[0], y: xy[1]) }
                    self.emptyBoxMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: at))
                }
            }
        }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let menu = detailsMenu() else { return nil }
        return UIMenu(children: [menu])
    }

    /// "My details" with a submenu for each kind of detail.
    private func detailsMenu() -> UIMenu? {
        let groups = Self.details()
        guard !groups.isEmpty else { return nil }
        let menus = groups.map { group in
            UIMenu(title: Self.title(group.kind), children: group.values.map { value in
                UIAction(title: value) { [weak self] _ in self?.put(value) }
            })
        }
        return UIMenu(title: Loc.t("My details"), image: UIImage(systemName: "person.text.rectangle"), children: menus)
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard textBoxFocused, builder.system == .context, let menu = detailsMenu() else { return }
        builder.insertChild(menu, atStartOfMenu: .standardEdit)
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
