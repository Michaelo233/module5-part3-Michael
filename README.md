# Project Overview
The Student Portfolio Microservice aims to provide a platform where students can showcase their projects, skills, and academic achievements. It's built with scalability and modularity in mind, allowing for independent development and deployment of the frontend and backend components.

## Architecture
**The application follows a simple microservice pattern:**

## Frontend: A client-side application (e.g., React, Angular, Vue.js) responsible for the user interface and interactions.

    Frontend: A client-side application (e.g., React, Angular, Vue.js) responsible for the user interface and interactions.

    Backend: A server-side application (e.g., Node.js with Express, Python with Flask/Django, Java with Spring Boot) that handles business logic, API requests, and interacts with the database.

    Transactions: A service specifically for managing and processing all financial transactions related to student portfolios, such as payments for premium features or certifications.

    Nginx: Serves as the entry point for all incoming HTTP requests. It acts as a reverse proxy, directing requests to either the frontend static files or proxying API calls to the backend service.

    MongoDB: A NoSQL database used by the backend service to store all application data (e.g., student profiles, project details, skills).


+------------------+     +-------------------+     +-------------------+     +--------------+
|      Client      | <-> |   Nginx (Port 80) | <-> |     Frontend      |     |              |
| (Web Browser)    |     | (Reverse Proxy)   |     | (Static Files)    |     |              |
+------------------+     +-------------------+     +-------------------+     |   MongoDB    |
                                   |                                         |  (Database)  |
                                   | API Calls (via Nginx reverse proxy)     |              |
                                   v                                         |              |
                                +-------------------+ <---------------------+--------------+
                                |      Backend      |
                                |   (API Service)   |
                                +-------------------+
                                          |
                                          |
                                          v
                                +-----------------------+
                                |      Transactions     |
                                | (Payment Processing)  |
                                +-----------------------+
## Technologies Used
    Frontend: [Specify your frontend framework/library, e.g., React, Angular, Vue.js, or just HTML/CSS/JS]

    Backend: [Specify your backend language/framework, e.g., Node.js/Express, Python/Flask, Java/Spring Boot]

    Transactions: [Specify the technology for the new transactions microservice, e.g., a dedicated microservice using Stripe, PayPal, or another payment gateway.]

    Database: MongoDB

    API Proxy/Web Server: Nginx

    Containerization (Recommended): Docker, Docker Compose (for local development)

## Deployment Script

Run the deployment from any current directory by specifying the path to the script:

```bash
bash /path/to/deploy.sh
```

The script performs these actions, in order:

1. Enables Bash safety options so unset variables and command failures are handled explicitly.
2. Checks for Git and installs it with apt or Homebrew when missing.
3. Clones `https://github.com/Michaelo233/module5-part3-Michael.git` into `module5-part3-Michael` under the current directory, or reuses that directory if it is already a checkout with the expected origin. Set `DEPLOY_REPO_DIR` to choose another destination.
4. Changes into the checkout, then checks Docker, Docker Compose, and daemon availability. In WSL, it uses `docker.exe` when available and attempts to start Docker Desktop if the daemon is unreachable, waiting up to two minutes for it to become ready.
5. Verifies `docker-compose.yml` and checks ports 3000, 5000, and 80 with `ss` or `lsof`. Ports already published by this project's running services are allowed so the script can be rerun safely.
6. Runs `docker compose up -d --build` to build and start the services.
7. Waits for HTTP responses from the transactions service (3000), backend (5000), and Nginx (80), printing service logs if one does not respond.
8. Displays the Compose service state and lists local Docker images and running containers.
9. Finds and prints the Nginx container ID for this Compose project, failing if it is not running.
10. Requests port 80 and verifies that the HTML contains the portfolio title.
11. Installs `jq` with apt or Homebrew if it is missing, or reports that it must be installed manually.
12. Writes `docker image inspect nginx:alpine` output to `nginx-logs`.
13. Uses `jq` to print the image repository tags, creation date, operating system, full configuration, and exposed ports.

## Minikube Deployment

Deploy the Kubernetes application with the Docker driver and build the application images directly into Minikube's Docker daemon:

```bash
bash /path/to/apply_minikube_dockerenv.sh
```

The script checks for Git and installs it with apt or Homebrew when missing. It clones the repository into `module5-part3-Michael` under the current directory, or reuses that directory if it is already a checkout with the expected origin. Set `DEPLOY_REPO_DIR` to choose another destination.

The script uses the `minikube` profile by default. To use another profile, set `MINIKUBE_PROFILE` (for example, `MINIKUBE_PROFILE=dev bash /path/to/apply_minikube_dockerenv.sh`). It builds and verifies the backend, portfolio, and transactions images, applies the manifests in `k8s/`, restarts the deployments, waits for all baseline workload rollouts, verifies at least ten application pods, and checks the five Services' endpoints. No cluster-specific manifest edits are needed.

After deployment, launch the Nginx Service with:

```bash
minikube service nginx
```

If you deployed with a non-default profile, specify it with `minikube --profile "$MINIKUBE_PROFILE" service nginx`. To observe pods as they are created, run `kubectl --context="${MINIKUBE_PROFILE:-minikube}" get pods --watch` in another terminal while the script runs.