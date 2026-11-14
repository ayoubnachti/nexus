pipeline {
  agent none   // every stage picks its own agent

  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()      // one build at a time per branch/PR; a new push waits in the queue
  }

  triggers {
    // Nightly test + analysis of main, so code health is re-checked even without pushes.
    // In a Multibranch job every branch/PR has its own triggers: only main gets a schedule.
    cron(env.BRANCH_NAME == 'main' ? 'H 3 * * *' : '')
  }

  environment {
    TAG     = "${BUILD_NUMBER}"                        // image tag for this build
    COMPOSE = 'docker compose -p ecommerce -f compose.yml'
    BACKEND_SVCS = 'discovery-server api-gateway user-service product-service media-service order-service cart-service'
    DEPLOY       = 'true'
    NEXUS_URL    = 'https://nexus.ayoubnachti.dev'
  }

  stages {
    // Runs before the parallel branches, so both see SONAR_ARGS
    stage('Prepare') {
      steps {
        script {
          // Tell SonarQube what is being analysed: a PR (compared against its target) or a branch
          env.SONAR_ARGS = env.CHANGE_ID
            ? "-Dsonar.pullrequest.key=${env.CHANGE_ID} -Dsonar.pullrequest.branch=${env.CHANGE_BRANCH} -Dsonar.pullrequest.base=${env.CHANGE_TARGET}"
            : "-Dsonar.branch.name=${env.BRANCH_NAME}"
        }
      }
    }

    stage('Build & test') {
      parallel {
        // One agent + one workspace for tests and analysis: the analysis reuses
        // the compiled classes and the JaCoCo reports produced by the tests
        stage('Backend') {
          agent { label 'backend' }
          environment {
            JWT_SECRET            = 'Y2ktdGVzdC1vbmx5LWp3dC1rZXktbm90LWEtcmVhbC1zZWNyZXQ='
            SERVER_SSL_ENABLED    = 'false'
            SSL_KEYSTORE_PASSWORD = 'unused'
            CLOUDINARY_URL        = 'cloudinary://test-key:test-secret@test-cloud'
          }
          stages {
            stage('Backend tests') {
              steps {
                withCredentials([usernamePassword(credentialsId: 'nexus-ci',
                                                  usernameVariable: 'NEXUS_USER',
                                                  passwordVariable: 'NEXUS_PASSWORD')]) {
                  sh '''
                    for svc in $BACKEND_SVCS; do
                      echo "=== Testing $svc"
                      (cd backend/$svc && MONGODB_URI="mongodb://mongo-test:27017/buy-02-$svc-test" ./mvnw -s ../../settings.xml -B -ntp clean \
                        org.jacoco:jacoco-maven-plugin:0.8.15:prepare-agent \
                        test \
                        org.jacoco:jacoco-maven-plugin:0.8.15:report)
                    done
                  '''
                }
              }
              post {
                always {
                  junit allowEmptyResults: true, testResults: 'backend/*/target/surefire-reports/*.xml'
                }
              }
            }

            stage('Backend analysis') {
              steps {
                fetchTargetBranch()
                withCredentials([usernamePassword(credentialsId: 'nexus-ci',
                                                  usernameVariable: 'NEXUS_USER',
                                                  passwordVariable: 'NEXUS_PASSWORD')]) {
                  withSonarQubeEnv('sonarqube') {
                    sh '''
                      for svc in $BACKEND_SVCS; do
                        echo "=== Analysing $svc"
                        (cd backend/$svc && ./mvnw -s ../../settings.xml -B -ntp \
                          org.sonarsource.scanner.maven:sonar-maven-plugin:5.8.0.7211:sonar \
                          -Dsonar.projectKey=buy-02-$svc \
                          "-Dsonar.projectName=buy-02 $svc" \
                          -Dsonar.qualitygate.wait=true \
                          -Dsonar.qualitygate.timeout=300 \
                          $SONAR_ARGS)
                      done
                    '''
                  }
                }
              }
            }
          }
        }

        stage('Frontend') {
          agent { label 'frontend' }
          stages {
            stage('Frontend tests') {
              steps {
                dir('frontend') {
                  sh 'npm ci'
                  sh 'npx ng build' 
                  sh 'npx ng test --watch=false --coverage --coverage-reporters=lcov --reporters=junit --reporters=default --output-file=test-results/junit.xml'
                }
              }
              post {
                always {
                  junit allowEmptyResults: true, testResults: 'frontend/test-results/junit.xml'
                }
              }
            }

            stage('Frontend analysis') {
              steps {
                fetchTargetBranch()
                dir('frontend') {
                  withSonarQubeEnv('sonarqube') {
                    sh '''
                      npx @sonar/scan \
                        -Dsonar.projectKey=buy-02-frontend \
                        "-Dsonar.projectName=buy-02 frontend" \
                        -Dsonar.sources=src \
                        -Dsonar.tests=src \
                        "-Dsonar.exclusions=**/*.spec.ts" \
                        "-Dsonar.test.inclusions=**/*.spec.ts" \
                        -Dsonar.javascript.lcov.reportPaths=coverage/frontend/lcov.info \
                        -Dsonar.qualitygate.wait=true \
                        -Dsonar.qualitygate.timeout=300 \
                        $SONAR_ARGS
                    '''
                  }
                }
              }
            }
          }
        }
      }
    }

    // Runs only for pushes to main, and only if tests and quality gates passed.
    // One deploy, tested in place: Deploy replaces the live containers, then
    // E2E tests runs against that same live site before this stage decides
    // whether to keep it. Only a build whose deploy health-checked AND
    // passed e2e becomes "last-good" — a failure in either rolls back.
    stage('Deliver') {
      when {
        branch 'main'
        environment name: 'DEPLOY', value: 'true'
        not { triggeredBy 'TimerTrigger' }   // the nightly run tests and analyses, but doesn't redeploy
        beforeAgent true                     // check first, so PR and nightly builds don't take the backend agent
      }
      agent { label 'backend' }   // default for children below; E2E tests overrides it
      environment {
        VERSION  = "1.0.${BUILD_NUMBER}"              // the release version: JARs in maven-releases, images in docker-hosted
        REGISTRY = 'registry.ayoubnachti.dev'
      }
      stages {
        stage('Build images') {
          steps {
            withCredentials([file(credentialsId: 'ecommerce-env', variable: 'APP_ENV'),
                              usernamePassword(credentialsId: 'nexus-ci',
                                              usernameVariable: 'NEXUS_USER',
                                              passwordVariable: 'NEXUS_PASSWORD')]) {
              sh '''
                set +x                           # don't echo commands: they contain the keystore password
                set -a; . "$APP_ENV"; set +a     # load the app's settings (keystore password)

                # The gateway's keystore is git-ignored and packaged into its JAR,
                # so it must exist before Maven builds that JAR
                KS=backend/api-gateway/src/main/resources/keystore.p12
                rm -f "$KS"
                keytool -genkeypair -noprompt -alias gateway -keyalg RSA -keysize 2048 \
                  -storetype PKCS12 -validity 3650 -keystore "$KS" -dname "CN=localhost" \
                  -storepass "$SSL_KEYSTORE_PASSWORD" -keypass "$SSL_KEYSTORE_PASSWORD"

                # Build each JAR once, through Nexus, with the release version.
                # The Dockerfiles only copy target/*.jar, so the image holds exactly this JAR,
                # and Publish uploads the same file to maven-releases.
                for svc in $BACKEND_SVCS; do
                  echo "=== Packaging $svc $VERSION"
                  (cd backend/$svc && ./mvnw -s ../../settings.xml -B -ntp clean package -DskipTests -Drevision=$VERSION)
                done

                $COMPOSE --env-file "$APP_ENV" build
              '''
          }
        }

        stage('Deploy') {
          steps {
            withCredentials([file(credentialsId: 'ecommerce-env', variable: 'APP_ENV')]) {
              // --wait: succeed only when every container reports healthy
              sh '$COMPOSE --env-file "$APP_ENV" up -d --wait --wait-timeout 300'
            }
          }
        }

        // Runs on the frontend agent (it has Node; the backend agent has no
        // browser deps) against the site Deploy just put live.
        stage('E2E tests') {
          agent { label 'frontend' }
          environment {
            E2E_BASE_URL = 'https://shop.ayoubnachti.dev'
            PLAYWRIGHT_BROWSERS_PATH = '/ms-playwright'
            READY_URL = 'https://shop.ayoubnachti.dev/api/products'
          }
          steps {
            dir('frontend') {
              sh 'npm ci'
              sh '''
                for i in $(seq 1 24); do
                  if node -e "fetch(process.env.READY_URL).then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"; then
                    echo "Stack is ready"; exit 0
                  fi
                  echo "Waiting for the stack to answer ($i/24)..."; sleep 5
                done
                echo "Stack did not become ready in 2 minutes"; exit 1
              '''
              sh 'npx playwright test'
            }
          }
          post {
            always {
              dir('frontend') {
                junit allowEmptyResults: true, testResults: 'test-results/e2e-junit.xml'
                archiveArtifacts artifacts: 'playwright-report/**', allowEmptyArchive: true
              }
            }
          }
        }

        // Only a release that deployed healthy and passed E2E gets a version in Nexus.
        // Back on the backend agent, in the workspace where Build images left the JARs.
        // If Nexus refuses anything, Deliver fails and rolls back like any other failure.
        stage('Publish') {
          steps {
            withCredentials([usernamePassword(credentialsId: 'nexus-ci',
                                              usernameVariable: 'NEXUS_USER',
                                              passwordVariable: 'NEXUS_PASSWORD')]) {
              sh '''
                # JARs: upload the exact files the images were built from (no rebuild),
                # with the flattened pom, whose version is the real one (1.0.N, not ${revision})
                for svc in $BACKEND_SVCS; do
                  echo "=== Publishing $svc $VERSION to maven-releases"
                  (cd backend/$svc && ./mvnw -s ../../settings.xml -B -ntp deploy:deploy-file \
                    -Dfile="$(ls target/*.jar)" \
                    -DpomFile=.flattened-pom.xml \
                    -DrepositoryId=nexus-releases \
                    -Durl="$NEXUS_URL/repository/maven-releases/")
                done

                # Images: a throwaway Docker config, so the registry login never stays on the agent
                export DOCKER_CONFIG=$(mktemp -d)
                trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                echo "$NEXUS_PASSWORD" | docker login "$REGISTRY" -u "$NEXUS_USER" --password-stdin
                for svc in $BACKEND_SVCS frontend; do
                  echo "=== Pushing $REGISTRY/ecommerce/$svc:$VERSION"
                  docker tag ecommerce/$svc:$TAG $REGISTRY/ecommerce/$svc:$VERSION
                  docker push $REGISTRY/ecommerce/$svc:$VERSION
                done
                docker logout "$REGISTRY"
              '''
            }
          }
          post {
            always {
              // Drop the registry tags locally (the images stay as ecommerce/<svc>:<build#>).
              // Untag by name only: removing by image id would also delete the deploy's tags.
              sh '''
                docker images "$REGISTRY/ecommerce/*" --format '{{.Repository}}:{{.Tag}}' \
                  | xargs -r docker rmi
              '''
            }
          }
        }
      }
      post {
        // Runs on this stage's own agent (backend), regardless of which
        // child — Deploy or E2E tests — passed or failed.
        success {
          // Deploy health-checked AND e2e passed: remember it as the one to roll back to
          sh '''
            for svc in $BACKEND_SVCS frontend; do
              docker tag ecommerce/$svc:$TAG ecommerce/$svc:last-good
            done
            docker images 'ecommerce/*' --format '{{.Repository}}:{{.Tag}}' \
              | grep -vE ":($TAG|last-good)$" \
              | xargs -r docker rmi
            docker image prune -f
          '''
          script { env.DEPLOYED = 'true' }   // reported in the email
        }
        failure {
          script {
            // Roll back only if a previous healthy release exists
            if (sh(returnStatus: true, script: 'docker image inspect ecommerce/api-gateway:last-good > /dev/null 2>&1') == 0) {
              echo "Build ${TAG} failed its health check or e2e test: rolling back to last-good"
              withCredentials([file(credentialsId: 'ecommerce-env', variable: 'APP_ENV')]) {
                sh 'TAG=last-good $COMPOSE --env-file "$APP_ENV" up -d --wait --wait-timeout 300'
              }
              env.ROLLED_BACK = 'true'   // reported in the email
            } else {
              echo 'Deploy or e2e failed and there is no previous good release to roll back to'
            }
          }
        }
      }
    }
  }

  post {
    success {
      emailext(
        to: '$DEFAULT_RECIPIENTS',
        subject: "SUCCESS: ${env.JOB_NAME} #${env.BUILD_NUMBER}" + (env.DEPLOYED ? ' deployed' : ' (tests and analysis passed)'),
        body: """Build #${env.BUILD_NUMBER} of ${env.BRANCH_NAME} passed all tests and quality gates.
                    ${env.DEPLOYED ? "Deployed and published as version 1.0.${env.BUILD_NUMBER} (JARs in maven-releases, images in registry.ayoubnachti.dev/ecommerce/*:1.0.${env.BUILD_NUMBER})." : 'Not deployed: only pushes to main deploy (PR builds and the nightly scan do not).'}

          Changes: ${env.BUILD_URL}changes
          Console: ${env.BUILD_URL}console
        """
      )
    }
    failure {
      emailext(
        to: '$DEFAULT_RECIPIENTS',
        subject: "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}" + (env.ROLLED_BACK ? ' (rolled back)' : ''),
        body: """Build #${env.BUILD_NUMBER} of ${env.BRANCH_NAME} failed.
          ${env.ROLLED_BACK ? 'The new release was unhealthy, so the previous good release (last-good) was redeployed. The site is still up.' : 'Nothing new was deployed: the running release is unchanged.'}

          Test results: ${env.BUILD_URL}testReport
          Console: ${env.BUILD_URL}console
        """
      )
    }
  }
}

def fetchTargetBranch() {
  if (env.CHANGE_ID) {
    withCredentials([gitUsernamePassword(credentialsId: 'git-token')]) {
      sh 'git fetch --no-tags origin "+refs/heads/$CHANGE_TARGET:refs/remotes/origin/$CHANGE_TARGET"'
    }
  }
}