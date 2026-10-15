"""Week 7 · Kubernetes cluster topology of ShopLite (Diagrams as Code, mingrammer/diagrams).

Render: scripts/render-diagrams.sh  (→ k8s-cluster-topology.png)
Mirrors k8s/ exactly: namespaces, Deployments → ReplicaSets → Pods, StatefulSet + PVC/PV,
Services, Ingress, ConfigMaps, Secret and NetworkPolicies, plus pod placement per node.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.k8s.compute import Deployment, Pod, ReplicaSet, StatefulSet
from diagrams.k8s.network import Ingress, NetworkPolicy, Service
from diagrams.k8s.podconfig import ConfigMap, Secret
from diagrams.k8s.storage import PV, PVC, StorageClass
from diagrams.onprem.client import Users
from diagrams.onprem.network import Traefik

NORTH_SOUTH = "#2f5d8a"
EAST_WEST = "#b07d10"
DATA = "#1f7a3f"
CONFIG = "#8a8a84"
OWNS = "#b9b9b3"

graph_attr = {
    "fontsize": "22",
    "fontname": "Helvetica",
    "pad": "0.4",
    "nodesep": "0.45",
    "ranksep": "0.9",
    "splines": "spline",
    "labelloc": "t",
}
node_attr = {"fontsize": "11", "fontname": "Helvetica"}


def app_tier(name, component, port_note, extra_cm=None):
    """Deployment → ReplicaSet → 2 pods (one per worker) behind a ClusterIP Service."""
    with Cluster(f"{name} · {component}", graph_attr={"bgcolor": "#f4f8fc", "fontsize": "13"}):
        svc = Service(f"svc/{name}\nClusterIP {port_note}")
        dep = Deployment(f"deploy/{name}\nreplicas 2 · maxUnavailable 0")
        rs = ReplicaSet(f"rs/{name}-<hash>")
        pods = [Pod(f"{name} pod\n@ worker"), Pod(f"{name} pod\n@ worker2")]
        dep >> Edge(color=OWNS, style="dashed") >> rs
        rs >> Edge(color=OWNS, style="dashed") >> pods
        svc >> Edge(color=NORTH_SOUTH) >> pods
        cm = ConfigMap(extra_cm) if extra_cm else None
    return svc, pods, cm


with Diagram(
    "ShopLite · Kubernetes cluster topology (kind · K8s v1.37 · 1 control-plane + 2 workers)",
    filename="docs/week7/diagrams/k8s-cluster-topology",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    users = Users("Client\ncurl / browser")

    with Cluster("kind cluster \"shoplite\"", graph_attr={"bgcolor": "#ffffff", "fontsize": "15"}):
        sc = StorageClass("sc/standard\nlocal-path")

        with Cluster(
            "namespace ingress-traefik · PSA restricted",
            graph_attr={"bgcolor": "#eef1f6", "fontsize": "14"},
        ):
            np_svc = Service("svc/traefik\nNodePort 30080 → :8000")
            traefik = [Traefik("traefik pod\n@ worker"), Traefik("traefik pod\n@ worker2")]
            np_svc >> Edge(color=NORTH_SOUTH) >> traefik

        with Cluster(
            "namespace shop · PSA restricted · NetworkPolicy default-deny",
            graph_attr={"bgcolor": "#fafaf8", "fontsize": "14"},
        ):
            ing = Ingress("ingress/shop\nhost shop.local\nclass traefik")
            netpol = NetworkPolicy(
                "4 NetworkPolicies\ndefault-deny-ingress\nallow-from-ingress-controller\n"
                "allow-orders-to-catalog\nallow-apps-to-postgres"
            )
            secret = Secret("secret/db-credentials-<hash>\n3 keys · kustomize secretGenerator")

            web_svc, web_pods, web_cm = app_tier("web", "frontend · nginx", "80→8080", "cm/web-config\n(file config.json)")
            cat_svc, cat_pods, cat_cm = app_tier("catalog", "api · Node.js", "80→8080", "cm/catalog-config\n(envFrom)")
            ord_svc, ord_pods, ord_cm = app_tier("orders", "api · Node.js", "80→8080", "cm/orders-config\n(envFrom)")

            with Cluster("postgres · data tier", graph_attr={"bgcolor": "#f2f8f3", "fontsize": "13"}):
                pg_svc = Service("svc/postgres\nheadless (clusterIP None)")
                sts = StatefulSet("sts/postgres\nreplicas 1")
                pg_pod = Pod("postgres-0\n@ worker2")
                pvc = PVC("pvc/data-postgres-0\n1Gi RWO")
                pg_cm = ConfigMap("cm/postgres-init\n(init script volume)")
                sts >> Edge(color=OWNS, style="dashed") >> pg_pod
                pg_svc >> Edge(color=DATA) >> pg_pod
                pg_pod >> Edge(color=DATA) >> pvc

        pv = PV("pv/pvc-…\nhostPath on worker2")

    # north-south path
    users >> Edge(color=NORTH_SOUTH, label="127.0.0.1:8080", penwidth="2") >> np_svc
    for t in traefik:
        t >> Edge(color=NORTH_SOUTH, style="dotted") >> ing
    ing >> Edge(color=NORTH_SOUTH, label="/", penwidth="1.6") >> web_svc
    ing >> Edge(color=NORTH_SOUTH, label="/api/catalog", penwidth="1.6") >> cat_svc
    ing >> Edge(color=NORTH_SOUTH, label="/api/orders", penwidth="1.6") >> ord_svc

    # east-west + data paths
    for p in ord_pods:
        p >> Edge(color=EAST_WEST, label="GET price", penwidth="1.4") >> cat_svc
    for p in cat_pods + ord_pods:
        p >> Edge(color=DATA, style="bold") >> pg_svc

    # storage
    pvc >> Edge(color=DATA, label="bound") >> pv
    sc >> Edge(color=OWNS, style="dashed", label="provisions") >> pv

    # configuration injection
    web_cm >> Edge(color=CONFIG, style="dotted") >> web_pods
    cat_cm >> Edge(color=CONFIG, style="dotted") >> cat_pods
    ord_cm >> Edge(color=CONFIG, style="dotted") >> ord_pods
    pg_cm >> Edge(color=CONFIG, style="dotted") >> pg_pod
    secret >> Edge(color="#b42318", style="dotted", label="PGPASSWORD") >> [cat_pods[0], ord_pods[0]]
    secret >> Edge(color="#b42318", style="dotted", label="files") >> pg_pod
    netpol >> Edge(color="#b42318", style="invis") >> pg_svc
