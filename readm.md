# AWS SES + S3 (thepuregrace.com)

## O que foi pedido
- Receber emails de `domains@`, `admin@`, `billing@`.
- Salvar no S3 por **pasta do endereço** e **data** (`YYYY/MM/DD`).
- Nome do arquivo com **data + hora + milissegundos**.
- **Não apagar** o `incoming/`.
- Encaminhar para `dayvson.red@gmail.com`, exceto quando esse endereço estiver como destinatário original.

## Como funciona
1. SES recebe o email.
2. SES salva o **email bruto** no S3 com chave `incoming/<message-id>`.
3. Evento do S3 dispara a Lambda.
4. Lambda salva o `.eml` em:
   - `domains/YYYY/MM/DD/YYYYMMDDTHHMMSS.mmmZ-<message-id>.eml`
   - `admin/YYYY/MM/DD/...`
   - `billing/YYYY/MM/DD/...`
5. Lambda encaminha o conteúdo para `dayvson.red@gmail.com` (exceto quando esse endereço já está nos destinatários do email original).

## Estrutura criada
- `main.tf`
- `variables.tf`
- `outputs.tf`
- `emails_thegracepure_salve/lambda/index.js`

## O que falta preencher antes de aplicar
- `route53_zone_id` (ID da Hosted Zone do `thepuregrace.com`).

## Aplicar
```bash
terraform init
terraform apply -var="route53_zone_id=ZXXXXXXXXXXXXX"
```

## Observações importantes
- A Lambda usa `sendEmail` do SES para encaminhar. Ela **não reenvia o email bruto** como anexo.
- Se quiser anexar o `.eml`, precisaremos adicionar libs (ex: nodemailer + mailparser).
