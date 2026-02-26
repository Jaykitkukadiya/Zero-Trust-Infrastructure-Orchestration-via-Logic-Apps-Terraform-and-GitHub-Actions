# Zero-Trust Infrastructure Orchestration via Logic Apps, Terraform and, GitHub Actions

## Executive Summary
This repository contains **Part 2** of a comprehensive enterprise infrastructure initiative. While Part 1 established the foundational multi-region Active Directory and network topology.

The objective of this project was to completely automate the end-to-end lifecycle management of Virtual Desktop Infrastructure (VDI) machines based strictly on directory group membership. By integrating Azure Logic Apps, GitHub Actions, Terraform, and advanced Active Directory Group Policy Objects (GPOs), this pipeline dynamically provisions personalized Windows 11 virtual machines, joins them to a designated on-premises OU, enforces strict OS-level VDI security baselines, and automatically de-provisions resources when an employee departs—all with zero human intervention.

## Repository Structure & References
*   **`main.tf`**: The core Terraform configuration containing the dynamic provisioning and Azure VM extension logic.
*   **`.github/workflows/vdi.yml`**: The CI/CD pipeline triggered via `repository_dispatch`.
*   **`Proof of work/`**: This directory contains screenshots for reference.

## Business Justification & Cost Strategy
Modern infrastructure must be highly scalable and cost-efficient. Investing heavily in high-end physical laptops for every new hire introduces massive costs, supply chain delays, and data security risks. 

This infrastructure was designed with a **Cloud-First, Thin-Client Strategy**:
*   **Cost Efficiency:** By leveraging Azure's pay-as-you-go model, VDI compute is only paid for when needed.
*   **Hardware Agnostic:** The organization can standardize on low-cost, low-power physical endpoints (acting merely as dumb terminals/thin clients) to run the base OS and Remote Desktop client. 
*   **Seamless Offboarding & Asset Reusability:** If an employee is terminated, their Azure VDI is instantly destroyed, securing company data. The physical thin-client hardware can be immediately handed to a new hire without needing a wipe-and-reload, drastically reducing IT Service Desk overhead.

---

## Technology Stack & Architecture
*   **Infrastructure as Code (IaC):** Terraform
*   **Terraform State Management:** Azure Blob Storage (Secure)
*   **Event Orchestration:** Azure Logic Apps (Scheduled Identity Polling)
*   **CI/CD Pipeline:** GitHub Actions (`repository_dispatch` triggers defined in `vdi.yml`)
*   **Compute & Cloud:** Microsoft Azure (Windows 11 Pro 24H2, VMs, vNICs, Static Public IPs, NSGs) (Can be customizable based on the user’s requirements as part of future enhancements.)
*   **Configuration & Security Management:** Azure VM Extensions (`JsonADDomainExtension`, `CustomScriptExtension`), Active Directory Group Policy.

---

## The Zero-Touch Architectural Workflow

The pipeline scales infrastructure dynamically based entirely on Identity Provider (IdP) group membership. Because Terraform is declarative, the pipeline handles both **Creation** and **Destruction** flawlessly.

### Phase 1: Identity Polling & Orchestration (Azure Logic Apps)
1.  **Scheduled Trigger:** An Azure Logic App executes on a predefined schedule (e.g., daily).
2.  **Identity Query:** The Logic App queries the specific directory group (e.g., `VDI Standard Users`).
3.  **Data Sanitization:** It extracts the User Principal Names (UPNs), and other details and formats them into a clean JSON payload.
4.  **Webhook Dispatch:** The Logic App fires an HTTP POST request to the GitHub API(restricted to specific permissions for assigned repo only), utilizing a `repository_dispatch` event (type: `vdi_update`), passing the JSON user array as the `client_payload`.

### Phase 2: Pipeline Execution (GitHub Actions)
1.  **Initialization:** The runner authenticates to Azure using tightly scoped Service Principal credentials stored in GitHub Secrets.
2.  **Payload Injection:** The JSON array of users is converted to a string (`toJSON`) and injected directly into Terraform as an environment variable (`TF_VAR_user_list`).
3.  **Execution:** Terraform initializes the remote state, generates a plan, and auto-approves the deployment.

### Phase 3: Infrastructure-as-Code & Auto-Destruction (Terraform)
Using Terraform's `for_each` meta-argument, the configuration loops through the injected user list to build—or destroy—personalized environments:
1.  **Dynamic Provisioning:** For every new user in the JSON payload, a dedicated Resource Group, Static Public IP, Network Interface (NIC), and NSG (exposing port 3389) are created. A Windows 11 Pro machine (`Standard_B2s` with Secure Boot and vTPM) is provisioned.
2.  **Automated De-Provisioning (Tear Down):** If a user is removed from the Active Directory group, the Logic App payload will no longer contain their UPN. During the next run, Terraform compares the new payload against the state file and instantly triggers a `destroy` action for that user's specific Resource Group, wiping the VDI and stopping Azure billing immediately.

### Phase 4: Dynamic Configuration & Domain Join
1.  **Local AD Domain Join:** The `JsonADDomainExtension` passes service account credentials and injects the VM directly into the target on-premises environment (`lab.jaykit.local`). Crucially, the machine is explicitly routed to `OU=VDI-Computers`.
2.  **Zero-Touch User Assignment:** A `CustomScriptExtension` executes inline PowerShell to extract the user's domain prefix, secure RDP authentication registry keys, and add the specific user to the local **Remote Desktop Users** group.

---

## Phase 5: Zero-Trust Security & Post-Provisioning (Group Policy)

Placing the VMs specifically into the `OU=VDI-Computers` was a deliberate architectural decision. The moment the Terraform `JsonADDomainExtension` completes and the VM reboots, a highly customized suite of Active Directory GPOs is immediately enforced on the machine to optimize it for enterprise VDI workloads.

To ensure the fleet is secure, performant, and compliant, the following GPOs were engineered and linked to the target OU:

### 1. Microsoft Security Baseline Enforcement (Windows 11)
Rather than manually configuring security settings, the official Microsoft Security Baseline ADMX templates were imported into the Sysvol central store.

### 2. VDI Resource Optimization (RDP Session Timeouts)
To prevent users from abandoning active RDP sessions and consuming Azure compute/memory resources indefinitely, strict session time limits are enforced via GPO.
*   **Path:** `Computer Configuration > Administrative Templates > Windows Components > Remote Desktop Services > Remote Desktop Session Host > Session Time Limits`
*   **Settings:** Disconnected sessions limit (1 Hour) | Active but idle sessions limit (3 Hours).

### 3. Windows LAPS (Local Administrator Password Solution)
Terraform provisions the VM with a standard local admin password (`TF_VAR_vm_admin_password`). To prevent lateral movement, native Windows LAPS immediately rotates this password upon domain join and backs it up securely to Active Directory.
*   **Path:** `Computer Configuration > Administrative Templates > System > LAPS`

### 4. VDI Debloat & Consumer Features Disablement
Because Windows 11 Pro includes consumer-focused applications that waste VDI bandwidth (e.g., auto-downloading consumer apps), a GPO explicitly disables Microsoft Consumer Experiences.
*   **Path:** `Computer Configuration > Administrative Templates > Windows Components > Cloud Content`

### 5. Secure Network Drive Mapping (Item-Level Targeting)
VDI users require access to secure file shares. Instead of broad, legacy login scripts, Group Policy Preferences (GPP) were used.
*   **Implementation:** Mapped the `Z:` drive to `\\lab.jaykit.local\Shares\VDI-Data`. 
*   **Security:** Utilized **Item-Level Targeting** so the drive *only* mounts if the logged-in user is an active member of the `SG-VDI-Standard-Users` local AD security group.

---

## Highlights (For Technical Reviewers)

*   **Secure State Management:** Terraform state (`.tfstate`) contains highly sensitive plaintext data. Local state is strictly prohibited; it is locked and encrypted at rest in a dedicated Azure Storage Account (`tfstate30806`).
*   **Identity-Driven Lifecycle:** Traditional IaC requires manual updates to `.tfvars` files. By utilizing the logic app JSON payload combined with `for_each` loops, the infrastructure perfectly mirrors the IdP group.
*   **Least Privilege IAM:** No Domain Admin accounts are used. The domain join payload utilizes an account (`LAB\Administrator01`) delegated with strictly "Create/Delete Computer Object" rights directly on the `VDI-Computers` OU.

---

## Future Initiatives & Roadmap

While the current pipeline successfully treats VDI as cattle (standardized, disposable infrastructure), the roadmap for this architecture focuses on Hyper-Personalization and Cloud-Native Security.

### 1. Attribute-Driven Dynamic Infrastructure
Currently, the infrastructure is fixed per group (e.g., all users get a `Standard_B2s` VM). As a future initiative, I plan to make the infrastructure **dynamic based on individual user needs**. 
*   **Execution:** Active Directory User Attributes will be used to store a user's specific compute requirements in JSON at creation time. 
*   **The Flow:** The Logic App will read these attributes, pass them in the JSON payload, and Terraform will dynamically generate the exact VM size, disk tier, and network rules bespoke to that user. Terraform will maintain this isolated state per user.

### 2. Cloud-Native Management & Zero-Trust Integration (Intune & Defender)
Moving beyond local Active Directory GPOs, the next phase will fully embrace Microsoft's cloud security ecosystem:
*   **Intune Auto-Enrollment:** Configuring the environment so the newly joined VDI machines automatically enroll in Microsoft Intune upon user login for modern Mobile Device Management (MDM).
*   **Microsoft Defender for Endpoint (MDE):** Automating the deployment of the MDE sensor during the Terraform provisioning phase, seamlessly feeding telemetry into **Microsoft Sentinel** for centralized SIEM/SOAR monitoring.
*   **Microsoft Purview Compliance:** Implementing Data Loss Prevention (DLP) and Insider Risk Management policies via Purview to ensure that data residing on the dynamically generated VDIs meets strict organizational compliance standards. 

### 3. NSG Traffic Hardening
Modifying the dynamic NSG creation to restrict inbound RDP traffic (Port 3389) strictly to Azure VPN Gateways or trusted corporate IP ranges, deprecating the current `*` (any) allowance in `main.tf`.

## Related Projects
*   **[Part 1: Hybrid IAM across cloud and on-premises infrastructure](https://github.com/Jaykitkukadiya/Hybrid-IAM-across-cloud-and-on-premises-infrastructure)**: Documents the prerequisite infrastructure (Multi-Region Active Directory, Networking, and Entra Cloud Sync) that serves as the foundation for this automation engine.