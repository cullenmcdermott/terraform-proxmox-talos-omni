resource "tls_private_key" "private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "reg" {
  account_key_pem = tls_private_key.private_key.private_key_pem
  email_address   = var.acme_email
  external_account_binding {
    key_id      = var.acme_eab_kid
    hmac_base64 = var.acme_eab_hmac
  }
}

resource "acme_certificate" "omni" {
  account_key_pem = acme_registration.reg.account_key_pem
  common_name     = var.omni_common_name

  dns_challenge {
    provider = "cloudflare"
  }
}

resource "gpg_private_key" "omni_asc" {
  name     = "Omni etcd encryption"
  email    = var.acme_email
  rsa_bits = 4096
}

resource "proxmox_vm_qemu" "omni" {
  name        = var.vm_hostname
  agent       = 1
  os_type     = "cloud-init"
  target_node = var.proxmox_target_node
  desc        = var.vm_hostname
  memory      = var.vm_memory
  cores       = var.vm_cores
  iso         = var.proxmox_iso
  pxe         = false
  onboot      = true

  disks {
    scsi {
      scsi0 {
        disk {
          size    = var.vm_disk_size
          storage = var.vm_disk_storage
        }
      }

      # etcd
      scsi1 {
        disk {
          size    = 5
          storage = var.vm_disk_storage
        }
      }
    }
  }

  boot         = "order=scsi0;ide2"
  force_create = false
  scsihw       = "virtio-scsi-pci"
  qemu_os      = "l26"

  network {
    model    = "virtio"
    bridge   = "vmbr0"
    firewall = true
    macaddr  = var.vm_mac_addr
  }
  ipconfig0 = "ip=${var.vm_ip}/32,gw=${var.vm_gw}"
}

resource "talos_machine_secrets" "omni" {}

data "talos_machine_configuration" "omni" {
  cluster_name       = "omni"
  cluster_endpoint   = "https://${var.cluster_endpoint}:6443"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.omni.machine_secrets
  talos_version      = "v1.6.7"
  kubernetes_version = "v1.28.4"
}

data "talos_client_configuration" "this" {
  cluster_name         = "omni"
  client_configuration = talos_machine_secrets.omni.client_configuration
  endpoints            = [var.cluster_endpoint, proxmox_vm_qemu.omni.default_ipv4_address]
}

resource "talos_machine_configuration_apply" "omni" {
  client_configuration        = talos_machine_secrets.omni.client_configuration
  machine_configuration_input = data.talos_machine_configuration.omni.machine_configuration
  node                        = proxmox_vm_qemu.omni.default_ipv4_address
  apply_mode                  = "reboot"
  config_patches = [
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
        externalCloudProvider = {
          enabled = true,
          manifests = [
            "https://raw.githubusercontent.com/siderolabs/talos-cloud-controller-manager/main/docs/deploy/cloud-controller-manager.yml"
          ]
        }
      },
      machine = {
        kubelet = {
          extraArgs = {
            cloud-provider : "external",
            rotate-server-certificates = true
          },
        },
        features = {
          kubernetesTalosAPIAccess = {
            enabled = true,
            allowedRoles = [
              "os:reader"
            ],
            allowedKubernetesNamespaces = [
              "kube-system"
            ]
          }
        },
        install = {
          image = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.6.7"
          disk  = "/dev/sda"
        },
        disks = [
          {
            device = "/dev/sdb"
            partitions = [
              {
                mountpoint = "/var/mnt/etcd"
              }
            ]
          }
        ]
        network = {
          hostname = var.vm_hostname
          interfaces = [
            {
              interface = "enx${lower(replace(var.vm_mac_addr, ":", ""))}"
              dhcp      = true
              vip = {
                ip = var.cluster_endpoint
              }
            }
          ]
        }
      }
    }),
  ]
  depends_on = [proxmox_vm_qemu.omni]
}

resource "talos_machine_bootstrap" "omni" {
  client_configuration = talos_machine_secrets.omni.client_configuration
  node                 = proxmox_vm_qemu.omni.default_ipv4_address

  depends_on = [
    talos_machine_configuration_apply.omni,
    proxmox_vm_qemu.omni
  ]
}

output "taloscfg" {
  value = data.talos_client_configuration.this.talos_config
}

data "talos_cluster_kubeconfig" "omni" {
  client_configuration = talos_machine_secrets.omni.client_configuration
  node                 = proxmox_vm_qemu.omni.default_ipv4_address
}

resource "null_resource" "approve_certs" {
  provisioner "local-exec" {
    command = <<EOF
set -ex
export KUBECONFIG=${path.root}/kubeconfig
until nc -zv ${var.vm_ip} 6443; do
   kubectl get csr | grep Pending | awk '{print $1}' | xargs -L 1 kubectl certificate approve
   sleep 30
   kubectl get csr | grep Pending | awk '{print $1}' | xargs -L 1 kubectl certificate approve
    
done
    EOF
  }

  triggers = {
    taloscfg  = data.talos_client_configuration.this.talos_config
    bootstrap = talos_machine_bootstrap.omni.id
  }

  depends_on = [data.talos_cluster_kubeconfig.omni]
}

data "talos_cluster_health" "omni" {
  control_plane_nodes = [var.vm_ip]
  endpoints           = [var.cluster_endpoint, var.vm_ip]
  client_configuration = {
    client_certificate = talos_machine_secrets.omni.client_configuration.client_certificate
    ca_certificate     = talos_machine_secrets.omni.client_configuration.ca_certificate
    client_key         = talos_machine_secrets.omni.client_configuration.client_key
  }
  depends_on = [null_resource.approve_certs]
}

output "kubecfg" {
  value = data.talos_cluster_kubeconfig.omni.kubernetes_client_configuration
}


resource "local_file" "kubeconfig" {
  content  = data.talos_cluster_kubeconfig.omni.kubeconfig_raw
  filename = "${path.module}/scratch/kubeconfig"
}

resource "local_file" "taloscfg" {
  content  = data.talos_client_configuration.this.talos_config
  filename = "${path.module}/scratch/taloscfg"
}

resource "kubernetes_namespace" "omni" {
  metadata {
    name = "omni"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  depends_on = [data.talos_cluster_health.omni]
}

resource "random_uuid" "omni" {}

resource "kubernetes_secret" "omni_auth0" {
  metadata {
    namespace = "omni"
    name      = "omni-auth0"
  }
  data = {
    "client-id" = var.auth0_client_id
  }
  depends_on = [data.talos_cluster_health.omni]
}

resource "kubernetes_secret" "omni_tls" {
  metadata {
    namespace = "omni"
    name      = "omni-tls"
  }
  data = {
    "key.pem"  = acme_certificate.omni.private_key_pem
    "cert.pem" = "${acme_certificate.omni.certificate_pem}${acme_certificate.omni.issuer_pem}"
  }
  depends_on = [data.talos_cluster_health.omni]
}

resource "kubernetes_secret" "omni_gpg" {
  metadata {
    namespace = "omni"
    name      = "omni-gpg"
  }
  data = {
    "omni.asc" = gpg_private_key.omni_asc.private_key
  }
  depends_on = [data.talos_cluster_health.omni]
}


resource "kubernetes_deployment" "omni" {
  metadata {
    name      = "omni"
    namespace = "omni"
  }
  spec {
    selector {
      match_labels = {
        app = "omni"
      }
    }
    strategy {
      type = "Recreate"
    }
    replicas = 1
    template {
      metadata {
        name = "omni"
        labels = {
          app = "omni"
        }
      }
      spec {
        volume {
          name = "omni-tls"
          secret {
            secret_name = "omni-tls"
            items {
              key  = "key.pem"
              path = "key.pem"
            }
            items {
              key  = "cert.pem"
              path = "cert.pem"
            }
          }
        }

        volume {
          name = "omni-gpg"
          secret {
            secret_name = "omni-gpg"
            items {
              key  = "omni.asc"
              path = "omni.asc"
            }
          }
        }
        container {
          security_context {
            capabilities {
              add = [
                "NET_ADMIN"
              ]
            }
          }
          volume_mount {
            name       = "omni-tls"
            mount_path = "/tls"
          }

          volume_mount {
            name       = "omni-gpg"
            mount_path = "/gpg"
          }

          port {
            container_port = 443
            host_port      = 443
          }

          port {
            container_port = 8090
            host_port      = 8090
          }

          port {
            container_port = 8091
            host_port      = 8091
          }

          port {
            container_port = 8100
            host_port      = 8100
          }

          port {
            container_port = 50180
            host_port      = 50180
          }


          image = "ghcr.io/siderolabs/omni:v0.32.1"
          name  = "omni"
          command = [
            "/omni",
            "--account-id=${random_uuid.omni.id}",
            "--name=omni",
            "--cert=/tls/cert.pem",
            "--key=/tls/key.pem",
            "--siderolink-api-cert=/tls/cert.pem",
            "--siderolink-api-key=/tls/key.pem",
            "--private-key-source=file:///gpg/omni.asc",
            "--event-sink-port=8091",
            "--bind-addr=0.0.0.0:443",
            "--siderolink-api-bind-addr=0.0.0.0:8090",
            "--k8s-proxy-bind-addr=0.0.0.0:8100",
            "--advertised-api-url=https://${var.omni_common_name}/",
            "--siderolink-api-advertised-url=https://${var.omni_common_name}:8090/",
            "--siderolink-wireguard-advertised-addr=${var.vm_ip}:50180",
            "--advertised-kubernetes-proxy-url=https://${var.omni_common_name}:8100/",
            "--auth-auth0-enabled=true",
            "--auth-auth0-domain=${var.auth0_domain}",
            "--auth-auth0-client-id=$(AUTH0_CLIENT_ID)",
            "--initial-users=${join(",", var.initial_users)}",
          ]
        }
      }
    }
  }
  depends_on = [data.talos_cluster_health.omni]
}
