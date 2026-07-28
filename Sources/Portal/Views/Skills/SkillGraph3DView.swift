import SwiftUI
import WebKit

struct SkillGraph3DView: View {
    let graph: SkillGraph
    let onSelectSkill: (String) -> Void

    var body: some View {
        SkillGraphWebView(graph: graph, onSelectSkill: onSelectSkill)
            .background(Theme.background)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Knowledge Graph")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                    Text("\(graph.nodes.count) skills · \(graph.edges.count) relationships")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(10)
                .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
    }
}

#if os(macOS)
struct SkillGraphWebView: NSViewRepresentable {
    let graph: SkillGraph
    let onSelectSkill: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSkill: onSelectSkill) }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadGraphHTML(in: webView, graph: graph)
    }
}
#else
struct SkillGraphWebView: UIViewRepresentable {
    let graph: SkillGraph
    let onSelectSkill: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSkill: onSelectSkill) }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        loadGraphHTML(in: webView, graph: graph)
    }
}
#endif

extension SkillGraphWebView {
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onSelectSkill: (String) -> Void

        init(onSelectSkill: @escaping (String) -> Void) {
            self.onSelectSkill = onSelectSkill
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "skillGraph" else { return }
            if let body = message.body as? [String: Any],
               let type = body["type"] as? String,
               type == "selectSkill",
               let skillID = body["skillId"] as? String {
                onSelectSkill(skillID)
            }
        }
    }

    func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "skillGraph")
        let webView = WKWebView(frame: .zero, configuration: config)
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        return webView
    }

    func loadGraphHTML(in webView: WKWebView, graph: SkillGraph) {
        guard let data = try? JSONEncoder().encode(GraphPayload(graph: graph)),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.loadHTMLString(Self.html(json: json), baseURL: nil)
    }

    struct GraphPayload: Encodable {
        struct Node: Encodable { let id: String; let label: String; let group: String }
        struct Link: Encodable { let source: String; let target: String; let type: String }
        let nodes: [Node]
        let links: [Link]

        init(graph: SkillGraph) {
            nodes = graph.nodes.map { Node(id: $0.id, label: $0.label, group: $0.category ?? "") }
            links = graph.edges.map { Link(source: $0.source, target: $0.target, type: $0.type) }
        }
    }

    static func html(json: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body, canvas { margin:0; width:100%; height:100%; overflow:hidden; background:#1a1a1a; color:#f0f0f0; font-family:-apple-system,BlinkMacSystemFont,sans-serif; }
            #tip { position:fixed; right:12px; bottom:10px; color:#9a9a9a; font-size:12px; background:rgba(42,42,42,.78); padding:8px 10px; border-radius:10px; }
          </style>
        </head>
        <body>
          <canvas id="c"></canvas><div id="tip">Drag to rotate · scroll to zoom · click node to open</div>
          <script>
            const graph = \(json);
            const canvas = document.getElementById('c');
            const ctx = canvas.getContext('2d');
            let w=0,h=0,dpr=1, angleX=-0.42, angleY=0.72, zoom=1, drag=false, lastX=0, lastY=0;
            const colors=['#7c7cff','#5cb85c','#e8a838','#ff6b9d','#4dd0e1','#b388ff','#ffab40'];
            const groups=[...new Set(graph.nodes.map(n=>n.group||'root'))];
            const colorFor=g=>colors[Math.abs(hash(g||'root'))%colors.length];
            function hash(s){let h=0; for(let i=0;i<s.length;i++) h=((h<<5)-h)+s.charCodeAt(i)|0; return h;}
            graph.nodes.forEach((n,i)=>{ const a=i*2.399963, r=90+14*Math.sqrt(i); n.x=Math.cos(a)*r; n.y=Math.sin(a)*r; n.z=((i%17)-8)*18; });
            function resize(){ dpr=window.devicePixelRatio||1; w=innerWidth; h=innerHeight; canvas.width=w*dpr; canvas.height=h*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); draw(); }
            function project(n){
              let x=n.x, y=n.y, z=n.z;
              let cy=Math.cos(angleY), sy=Math.sin(angleY), cx=Math.cos(angleX), sx=Math.sin(angleX);
              let x1=x*cy-z*sy, z1=x*sy+z*cy, y1=y*cx-z1*sx, z2=y*sx+z1*cx;
              let scale=zoom*520/(520+z2);
              return {x:w/2+x1*scale, y:h/2+y1*scale, z:z2, s:scale};
            }
            function draw(){
              ctx.clearRect(0,0,w,h);
              const pos=new Map(graph.nodes.map(n=>[n.id, project(n)]));
              ctx.lineWidth=1;
              graph.links.forEach(l=>{
                const a=pos.get(l.source), b=pos.get(l.target);
                if(!a||!b) return;
                ctx.strokeStyle='rgba(124,124,255,.28)';
                ctx.beginPath();
                ctx.moveTo(a.x,a.y);
                ctx.lineTo(b.x,b.y);
                ctx.stroke();
              });
              graph.nodes.map(n=>({n,p:pos.get(n.id)})).sort((a,b)=>a.p.z-b.p.z).forEach(({n,p})=>{
                ctx.beginPath();
                ctx.fillStyle=colorFor(n.group);
                ctx.globalAlpha=Math.max(.45, Math.min(1, .72+p.s*.28));
                ctx.arc(p.x,p.y,Math.max(4,7*p.s),0,Math.PI*2);
                ctx.fill();
                ctx.globalAlpha=1;
                ctx.fillStyle='#f0f0f0'; ctx.font='12px -apple-system,BlinkMacSystemFont,sans-serif'; ctx.fillText(n.label,p.x+9,p.y+4);
              });
            }
            function nearest(x,y){ let best=null, bd=22; graph.nodes.forEach(n=>{ const p=project(n); const d=Math.hypot(p.x-x,p.y-y); if(d<bd){bd=d; best=n;} }); return best; }
            canvas.addEventListener('mousedown',e=>{drag=true;lastX=e.clientX;lastY=e.clientY});
            canvas.addEventListener('mousemove',e=>{ if(!drag) return; angleY+=(e.clientX-lastX)*.008; angleX+=(e.clientY-lastY)*.008; lastX=e.clientX; lastY=e.clientY; draw(); });
            addEventListener('mouseup',()=>drag=false);
            canvas.addEventListener('wheel',e=>{ e.preventDefault(); zoom=Math.max(.35,Math.min(4,zoom*(e.deltaY>0?.92:1.08))); draw(); }, {passive:false});
            canvas.addEventListener('click',e=>{
              const n=nearest(e.clientX,e.clientY);
              if(n){
                try{
                  window.webkit.messageHandlers.skillGraph.postMessage({type:'selectSkill', skillId:n.id});
                }catch(_){}
              }
            });
            addEventListener('resize',resize); resize();
          </script>
        </body>
        </html>
        """
    }
}
