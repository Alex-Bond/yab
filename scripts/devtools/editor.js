import {tags} from '@lezer/highlight';
import {EditorView,keymap,lineNumbers,highlightActiveLine,gutter,GutterMarker} from '@codemirror/view';
import {EditorState,StateEffect,StateField,RangeSet} from '@codemirror/state';
import {defaultKeymap,history,historyKeymap} from '@codemirror/commands';
import {syntaxHighlighting,defaultHighlightStyle,HighlightStyle,foldGutter,foldKeymap,bracketMatching} from '@codemirror/language';
import {searchKeymap,highlightSelectionMatches} from '@codemirror/search';
import {autocompletion,completionKeymap,closeBrackets,closeBracketsKeymap} from '@codemirror/autocomplete';
import {javascript} from '@codemirror/lang-javascript'; import {css} from '@codemirror/lang-css'; import {html} from '@codemirror/lang-html';
const post = data => window.webkit.messageHandlers.editor.postMessage(data);
const mark=StateEffect.define();
class Breakpoint extends GutterMarker {toDOM(){let b=document.createElement('span');b.textContent='●';b.className='bp';return b;}}
const breakpoints=StateField.define({create:()=>RangeSet.empty,update:(v,tr)=>{v=v.map(tr.changes);for(let e of tr.effects)if(e.is(mark))v=RangeSet.of(e.value.map(line=>new Breakpoint().range(tr.state.doc.line(Math.min(line,tr.state.doc.lines)).from)));return v;}});
let view, current, currentLine, currentDark;
const darkHighlight=HighlightStyle.define([{tag:tags.keyword,color:"#c792ea"},{tag:[tags.string,tags.regexp],color:"#c3e88d"},{tag:tags.number,color:"#f78c6c"},{tag:tags.comment,color:"#8b949e"},{tag:[tags.typeName,tags.className],color:"#ffcb6b"},{tag:[tags.propertyName,tags.attributeName],color:"#82aaff"},{tag:tags.tagName,color:"#f07178"}]);
const theme=EditorView.theme({'&':{height:'100%',fontSize:'12px',backgroundColor:'transparent'},'.cm-scroller':{overflow:'auto',fontFamily:'SFMono-Regular, Menlo, monospace'},'.cm-gutters':{backgroundColor:'transparent',color:'#808080',border:'none'},'.cm-lineNumbers .cm-gutterElement':{minWidth:'34px'},'.cm-content':{padding:'4px 0'},'&.cm-focused':{outline:'none'},'.cm-activeLine':{backgroundColor:'#80808010'},'.cm-activeLineGutter':{backgroundColor:'#80808015'}});
window.loadSource = data => {
 document.documentElement.style.colorScheme=data.dark?'dark':'light';document.body.style.color=data.dark?'#d6d6d6':'#202124';
 const appearanceChanged=currentDark!==data.dark;currentDark=data.dark;
 const same=current===data.id, navigate=!same||currentLine!==data.line;current=data.id;currentLine=data.line;
 const lang=data.language==='css'?css():data.language==='html'?html():javascript({typescript:data.language==='ts',jsx:true});
 const state=EditorState.create({doc:data.text,extensions:[lang,theme,EditorView.theme({"&":{color:data.dark?"#d6d6d6":"#202124"}},{dark:!!data.dark}),lineNumbers(),foldGutter(),highlightActiveLine(),history(),bracketMatching(),closeBrackets(),autocompletion(),highlightSelectionMatches(),syntaxHighlighting(data.dark?darkHighlight:defaultHighlightStyle),breakpoints,gutter({class:'cm-breakpoints',markers:v=>v.state.field(breakpoints),initialSpacer:()=>new Breakpoint(),domEventHandlers:{mousedown:(v,line)=>{post({kind:'breakpoint',line:v.state.doc.lineAt(line.from).number-1});return true;}}}),keymap.of([{key:'Mod-s',run:v=>{post({kind:'save',text:v.state.doc.toString()});return true;}},...defaultKeymap,...historyKeymap,...searchKeymap,...foldKeymap,...completionKeymap,...closeBracketsKeymap]),EditorView.updateListener.of(u=>{if(u.docChanged)post({kind:'changed',id:current,text:u.state.doc.toString()});})]});
 if(view){if(!same||appearanceChanged||(!data.echo&&view.state.doc.toString()!==data.text))view.setState(state);}else view=new EditorView({state,parent:document.getElementById('editor')});
 window.setBreakpoints(data.breakpoints||[]);
 if(navigate&&data.line>=0&&data.line<view.state.doc.lines){const p=view.state.doc.line(data.line+1).from;view.dispatch({selection:{anchor:p},effects:EditorView.scrollIntoView(p,{y:'center'})});}
};
window.setBreakpoints = lines => { if(view)view.dispatch({effects:mark.of(lines.map(l=>l+1))}); };
window.sourceText=()=>view?.state.doc.toString()||'';
post({kind:'ready'});
