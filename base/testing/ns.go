package main

import (
    "fmt"
    "os"

    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "context"
    // "metav1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/client-go/tools/clientcmd"
)


func main() {
    // Get the value of the `KUBECONFIG` environment variable.
    // kubeconfig := os.Getenv("KUBECONFIG")
    // 从环境变量或kubeconfig文件中获取Kubernetes配置
    config, err := rest.InClusterConfig()
    if err != nil {
        // 如果不在K8S集群内，可以使用kubeconfig文件来配置
        kubeconfig := os.Getenv("HOME") + "/.kube/config" // 修改为您的kubeconfig文件路径
        config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
        if err != nil {
            panic(err.Error())
        }
    }

    // 创建一个Kubernetes客户端集
    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        panic(err.Error())
    }

    // 获取所有的Namespace
    namespaces, err := clientset.CoreV1().Namespaces().List(context.TODO(), metav1.ListOptions{})
    if err != nil {
        panic(err.Error())
    }

    // 打印所有的Namespace名称
    for _, ns := range namespaces.Items {
        fmt.Println(ns.Name)
    }
}

