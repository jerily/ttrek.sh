FROM alpine:latest
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN pwd && ls -la
ADD artifacts/codedeploy-scripts /codedeploy-scripts

RUN chmod +x /codedeploy-scripts/AfterInstall.sh \
  && chmod +x /var/www/ttrek-app/run.sh

EXPOSE 10080

ENTRYPOINT ["/codedeploy-scripts/AfterInstall.sh"]
