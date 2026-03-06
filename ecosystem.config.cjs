module.exports = {
  apps: [
    {
      name: 'coderabbit-fixer',
      script: './fix-issues.sh',
      cwd: __dirname,
      interpreter: '/bin/bash',
      cron_restart: '*/30 * * * *',
      autorestart: false,
      watch: false,
      max_memory_restart: '200M',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      error_file: './logs/pm2-error.log',
      out_file: './logs/pm2-out.log',
      merge_logs: true
    }
  ]
}
