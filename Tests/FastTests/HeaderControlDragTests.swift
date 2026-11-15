import AppKit
import JavaScriptCore
import Testing
@testable import Fast

/// Execute the shipped script, including its queued pointer callbacks. The
/// prepared-app probe additionally checks actual DOMs and native event delivery.
@MainActor
struct HeaderControlDragTests {
    @Test func onlyEmptyHeaderBackgroundCanBeGrabbed() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var listeners={}, frames=[], messages=[], points=[], innerWidth=1000, target;
        var window=this; window.top=window;
        window.webkit={messageHandlers:{yabTopDrag:{postMessage:function(m){messages.push(m.grab);points.push([m.x,m.y])}}}};
        function addEventListener(name, f){listeners[name]=f}
        function requestAnimationFrame(f){frames.push(f)}
        function getSelection(){return {isCollapsed:true}}
        function getComputedStyle(n,pseudo){return {display:n.display||'block',cursor:n.cursor||'default',content:pseudo?(n.pseudo||'none'):'none'}}
        var document={elementFromPoint:function(){return target}};
        function element(tag,width,text,children){return {
          nodeType:1,tagName:tag,tabIndex:-1,children:children||[],
          firstChild:text?{nodeType:3,textContent:text,nextSibling:null}:null,
          getBoundingClientRect:function(){return {width:width}},
          getAttribute:function(k){return this[k]||null},
          hasAttribute:function(k){return this[k]!==undefined}
        }}
        function point(el,y){target=el;listeners.pointermove({clientX:500,clientY:y||25,pointerType:'mouse'});while(frames.length)frames.shift()();return messages.length?messages[messages.length-1]:false}
        """)
        context.evaluateScript(TopDragRelay.script.source)
        let result = context.evaluateScript("""
        var header=element('HEADER',1000,'',[{}]);
        var checks=[];
        checks.push(point(header)===true);
        target=header;listeners.pointermove({clientX:600,clientY:25,pointerType:'mouse'});
        while(frames.length)frames.shift()();
        checks.push(points[points.length-1][0]===600 && points[points.length-1][1]===25);
        // React-style controls, no role, hand cursor or inline handler.
        for(var tag of ['DIV','SPAN','IMG','SVG','BUTTON','A']){
          var control=element(tag,90,'Profile',[{}]);control.parentNode=header;
          checks.push(point(control)===false);
          checks.push(point(header)===true);
        }
        checks.push(point(element('DIV',80,'',[{}]))===false);
        checks.push(point(element('DIV',1000,'Plain header words',[{}]))===false);
        var labelled=element('DIV',1000,'',[{}]);labelled.pseudo='"Account"';
        checks.push(point(labelled)===false);
        var button=element('DIV',1000,'',[{}]);button.role='button';
        checks.push(point(button)===false);
        checks.push(point(header)===true);
        // A queued inside-band sample must not resurrect a drag after exit.
        target=header;listeners.pointermove({clientX:500,clientY:25,pointerType:'mouse'});
        listeners.pointermove({clientX:500,clientY:100,pointerType:'mouse'});
        while(frames.length)frames.shift()();checks.push(messages[messages.length-1]===false);
        var custom=element('SITE-HEADER',1000,'',[{}]);custom.display='flex';
        checks.push(point(custom)===true);
        checks.push(point(element('SITE-AVATAR',28,'V',[{}]))===false);
        checks.push(point(element('MENU',1000,'',[{}]))===true);
        // No pointermove: a newly mounted control must be checked against
        // the current DOM, not the last positive hover message.
        target=header;checks.push(window.__yabTopDragHit(500,25)===true);
        target=element('DIV',28,'V',[{}]);target.parentNode=header;
        checks.push(window.__yabTopDragHit(500,25)===false);
        checks.every(Boolean);
        """)
        #expect(context.exception == nil)
        #expect(result?.toBool() == true)
    }
}
