moved {
  from = module.alb.aws_lb_listener.frontend_http_tcp[0]
  to   = module.alb.aws_lb_listener.this["http"]
}

moved {
  from = module.alb.aws_lb_listener.frontend_https[0]
  to   = module.alb.aws_lb_listener.this["https"]
} 
  
moved {
  from = module.alb.aws_lb_target_group.main[0]
  to   = module.alb.aws_lb_target_group.this["tg-0"]
} 
  
moved {                                 
  from = module.alb.aws_lb_target_group.main[1]
  to   = module.alb.aws_lb_target_group.this["tg-1"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[0]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-0"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[1]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-1"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[2]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-2"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[3]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-3"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[4]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-4"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[5]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-5"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[6]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-6"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[7]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-7"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[8]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-8"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[9]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-9"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[10]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-10"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[11]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-11"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[12]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-12"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[13]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-13"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[14]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-14"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[15]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-15"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[16]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-16"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[17]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-17"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[18]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-18"]
}

moved {
  from = module.alb.aws_lb_listener_rule.https_listener_rule[19]
  to   = module.alb.aws_lb_listener_rule.this["https/rule-19"]
}


