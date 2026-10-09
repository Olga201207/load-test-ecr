# loglens-ecr

부하 테스트 대상(SUT) 이미지를 보관하는 ECR 리포지터리 `loglens-sut` 를 만드는 Terraform 스택.

명령어는 모두 **Windows CMD** 기준이다. 자격증명은 코드에 넣지 않으며, `AWS_PROFILE` 등 표준 자격증명 체인을 쓴다.

---

## 1. 왜 loglens-infra 와 분리했나

| | loglens-infra | loglens-ecr |
|---|---|---|
| 생명주기 | 쓸 때 apply, 안 쓸 때 destroy 반복 | 한 번 만들고 계속 유지 |
| 담는 것 | VPC, EKS, 관측 스택 | SUT 이미지 (롤백 대상) |
| 상태 파일 | `loglens-infra/terraform.tfstate` | `loglens-ecr/terraform.tfstate` |

상태가 분리되어 있으므로 loglens-infra 를 destroy 해도 리포지터리와 이미지는 그대로 남는다.
두 스택은 서로의 상태를 참조하지 않는다. 연결 고리는 이미지 주소 문자열 하나뿐이다.

EKS 노드 IAM 역할에는 EKS 모듈이 `AmazonEC2ContainerRegistryReadOnly` 를 이미 붙여 둔다.
그래서 클러스터에서 이 리포지터리를 pull 하는 데 loglens-infra 쪽 추가 설정은 필요 없다.

### 만드는 것

| 리소스 | 설정 | 이유 |
|---|---|---|
| `aws_ecr_repository.sut` | `image_tag_mutability = "IMMUTABLE"` | 같은 태그 덮어쓰기 금지. 태그가 특정 빌드로 고정되어 이전 태그로 되돌리면 롤백이 된다 |
| | `scan_on_push = true` | push 할 때마다 취약점 기본 스캔 |
| | `lifecycle.prevent_destroy = true` | 실수로 `terraform destroy` 해도 지워지지 않는다 (5절) |
| `aws_ecr_lifecycle_policy.sut` | 최신 10개만 유지 (`max_image_count`) | 저장 요금 방지. 태그 유무와 상관없이 push 시각 기준 |

> **IMMUTABLE 이므로 `latest` 같은 고정 태그는 두 번 push 할 수 없다.** 매 빌드마다 새 태그(버전 또는 커밋 해시)를 쓴다.

---

## 2. 최초 1회: 리포지터리 만들기

```bat
cd /d C:\Project\load-test-module\loglens-ecr

:: 자격증명 확인 (계정, 사용자)
aws sts get-caller-identity

terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

plan 에는 리소스 2개(`aws_ecr_repository.sut`, `aws_ecr_lifecycle_policy.sut`)가 추가로 나와야 한다.

apply 뒤 출력값:

```bat
terraform output
```

| output | 예시 | 용도 |
|---|---|---|
| `repository_url` | `123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/loglens-sut` | 이미지 주소. k8s 매니페스트의 `image` |
| `registry` | `123456789012.dkr.ecr.ap-northeast-2.amazonaws.com` | docker login 대상 |
| `docker_login_command` | `aws ecr get-login-password ... \| docker login ...` | 3절 |
| `push_command_example` | | 3절 |

이후로는 이 디렉터리에서 Terraform 을 다시 실행할 일이 거의 없다. `terraform.tfstate` 는 지우지 말고 보관한다 (6절).

---

## 3. 이미지 빌드와 푸시 (매번)

Docker Desktop 이 실행 중이어야 한다. `loglens-sut` 디렉터리(Dockerfile 이 있는 곳)에서 한다.

### 3-1. 리포지터리 주소를 변수로 받기

```bat
cd /d C:\Project\load-test-module\loglens-ecr
for /f "delims=" %i in ('terraform output -raw repository_url') do set REPO=%i
for /f "delims=" %i in ('terraform output -raw registry') do set REGISTRY=%i
echo %REPO%
```

> `.bat` 파일 안에 넣을 때는 `%i` 를 `%%i` 로 쓴다.

### 3-2. 로그인 (토큰 12시간 유효)

```bat
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin %REGISTRY%
```

`Login Succeeded` 가 나오면 된다. `terraform output -raw docker_login_command` 로 같은 명령을 볼 수 있다.

### 3-3. 태그 정하기

태그는 매번 새 값이어야 한다 (IMMUTABLE). 둘 중 하나를 쓴다.

```bat
:: (a) 버전을 직접 정한다
set TAG=0.1.0

:: (b) 현재 git 커밋 해시를 쓴다 (loglens-sut 가 git 저장소일 때)
cd /d C:\Project\load-test-module\loglens-sut
for /f "delims=" %i in ('git rev-parse --short HEAD') do set TAG=%i
```

코드를 고치지 않고 설정만 바꿔 다시 빌드할 때도 태그는 바꿔야 한다 (예: `0.1.0-2`).

### 3-4. 빌드와 푸시

```bat
cd /d C:\Project\load-test-module\loglens-sut
docker build --platform linux/amd64 -t %REPO%:%TAG% .
docker push %REPO%:%TAG%
```

- `--platform linux/amd64`: EKS 노드가 x86_64(`AL2023_x86_64_STANDARD`)다. ARM 머신에서 빌드해도 노드에서 돌도록 고정한다.
- 이미 있는 태그로 push 하면 `tag invalid: The image tag '...' already exists ... cannot be overwritten because the repository is immutable` 로 거부된다. 태그를 바꿔 다시 빌드한다.

### 3-5. 확인

```bat
:: 리포지터리의 이미지 목록 (최신순)
aws ecr describe-images --repository-name loglens-sut --region ap-northeast-2 ^
  --query "reverse(sort_by(imageDetails,&imagePushedAt))[].{tag:imageTags[0],pushed:imagePushedAt,sizeMB:imageSizeInBytes}" ^
  --output table

:: 스캔 결과 (push 직후에는 IN_PROGRESS 일 수 있다)
aws ecr describe-image-scan-findings --repository-name loglens-sut --image-id imageTag=%TAG% ^
  --region ap-northeast-2 --query "imageScanFindings.findingSeverityCounts"
```

---

## 4. 롤백

태그가 덮어써지지 않으므로, 쿠버네티스 매니페스트의 이미지 태그를 이전 값으로 바꿔 다시 적용하면 롤백이다.
수명 주기 정책이 최신 10개만 남기므로 **10번째 이전 빌드로는 되돌릴 수 없다.** 더 길게 보관하려면
`max_image_count` 를 늘린다 (`terraform.tfvars` 에 `max_image_count = 20` 후 plan / apply).

---

## 5. 리포지터리를 정말 지우려면

`prevent_destroy` 때문에 `terraform destroy` 는 오류로 멈춘다. 의도된 동작이다.
정말 지우려면:

1. `main.tf` 의 `lifecycle { prevent_destroy = true }` 블록을 지운다.
2. 이미지를 먼저 비운다. `force_delete = false` 라서 이미지가 남아 있으면 삭제가 거부된다.
   ```bat
   aws ecr batch-delete-image --repository-name loglens-sut --region ap-northeast-2 ^
     --image-ids imageTag=0.1.0 imageTag=0.1.1
   ```
3. `terraform destroy`

---

## 6. 상태 파일을 잃었을 때

local backend 이므로 `terraform.tfstate` 를 지우면 Terraform 은 리포지터리를 모른다.
그 상태로 apply 하면 `RepositoryAlreadyExistsException` 으로 실패한다. 이미 있는 리소스를 상태로 가져온다.

```bat
cd /d C:\Project\load-test-module\loglens-ecr
terraform init
terraform import aws_ecr_repository.sut loglens-sut
terraform import aws_ecr_lifecycle_policy.sut loglens-sut
terraform plan
```

plan 이 `No changes` 이면 복구된 것이다.
"# load-test-ecr" 
