FROM ubuntu:latest
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN pwd && ls -la
ADD artifacts/ttrek-app /app
ADD artifacts/codedeploy-scripts /codedeploy-scripts

RUN chmod +x /codedeploy-scripts/AfterInstall.sh \
  && chmod +x /app/run.sh

EXPOSE 8080

ENTRYPOINT ["/codedeploy-scripts/AfterInstall.sh"]
